#![recursion_limit = "256"]

use std::{
    collections::HashMap,
    fmt::Write as _,
    fs::{self, OpenOptions},
    io::Write,
    path::PathBuf,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use anyhow::{Context, Result, anyhow};
use base64::{Engine as _, engine::general_purpose::STANDARD as BASE64};
use fermium_core::{
    AccountSummary, ConnectionStatus, Event, ImageSummary, MessageKind, MessageSummary,
    PROTOCOL_VERSION, Request, RoomSummary,
};
use matrix_sdk::{
    Client, LoopCtrl, Room, RoomMemberships, RoomState,
    authentication::matrix::MatrixSession,
    config::SyncSettings,
    deserialized_responses::TimelineEvent,
    media::{MediaFormat, MediaRequestParameters, MediaRetentionPolicy},
    room::MessagesOptions,
    ruma::{
        RoomId,
        events::{
            AnySyncMessageLikeEvent, AnySyncTimelineEvent,
            room::{
                MediaSource,
                message::{MessageType, OriginalSyncRoomMessageEvent},
            },
        },
        serde::Raw,
    },
};
use serde::{Deserialize, Serialize};
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader, BufWriter},
    sync::{Mutex, mpsc},
};
use url::Url;

type EventSender = mpsc::Sender<Event>;
type SharedSessions = Arc<Mutex<HashMap<String, Session>>>;
type SharedPendingLogins = Arc<Mutex<HashMap<u64, PendingLogin>>>;

struct Session {
    client: Client,
    sync_task: Option<tokio::task::JoinHandle<()>>,
    store_key: String,
    initial_sync_complete: Arc<AtomicBool>,
    connection_state: Arc<Mutex<ConnectionState>>,
}

#[derive(Clone, Default)]
struct ConnectionState {
    status: Option<ConnectionStatus>,
    last_sync_timestamp: Option<i64>,
    error: Option<String>,
}

struct PendingLogin {
    client: Client,
    homeserver: String,
    store_key: String,
}

#[derive(Deserialize, Serialize)]
struct StoredSession {
    user_id: String,
    homeserver: String,
    store_key: String,
    session: MatrixSession,
}

#[tokio::main]
async fn main() -> Result<()> {
    let (events_tx, events_rx) = mpsc::channel(128);
    let writer = tokio::spawn(write_events(events_rx));
    let sessions: SharedSessions = Arc::new(Mutex::new(HashMap::new()));
    let pending_logins: SharedPendingLogins = Arc::new(Mutex::new(HashMap::new()));

    events_tx
        .send(Event::Ready {
            protocol_version: PROTOCOL_VERSION,
        })
        .await
        .context("helper output closed before ready event")?;

    restore_persisted_sessions(&sessions, &events_tx);

    let stdin = tokio::io::stdin();
    let mut lines = BufReader::new(stdin).lines();
    while let Some(line) = lines.next_line().await.context("reading helper input")? {
        if line.trim().is_empty() {
            continue;
        }

        let request = match serde_json::from_str::<Request>(&line) {
            Ok(request) => request,
            Err(error) => {
                send_error(&events_tx, None, "invalid_request", error.to_string()).await;
                continue;
            }
        };

        let should_quit = matches!(request, Request::Quit { .. });
        handle_request(
            request,
            Arc::clone(&sessions),
            Arc::clone(&pending_logins),
            events_tx.clone(),
        )
        .await;
        if should_quit {
            break;
        }
    }

    drop(events_tx);
    writer.await.context("waiting for helper output writer")??;
    Ok(())
}

async fn write_events(mut events: mpsc::Receiver<Event>) -> Result<()> {
    let stdout = tokio::io::stdout();
    let mut stdout = BufWriter::new(stdout);

    while let Some(event) = events.recv().await {
        let line = serde_json::to_string(&event).context("serializing helper event")?;
        stdout
            .write_all(line.as_bytes())
            .await
            .context("writing helper event")?;
        stdout
            .write_all(b"\n")
            .await
            .context("writing helper event newline")?;
        stdout.flush().await.context("flushing helper event")?;
    }

    Ok(())
}

async fn handle_request(
    request: Request,
    sessions: SharedSessions,
    pending_logins: SharedPendingLogins,
    events: EventSender,
) {
    let request_id = request.request_id();
    let result = match request {
        Request::Login {
            homeserver,
            username,
            password,
            ..
        } => {
            login(
                &sessions,
                &pending_logins,
                &events,
                request_id,
                homeserver,
                username,
                password,
            )
            .await
        }
        Request::LoginRecoveryKey {
            login_request_id,
            recovery_key,
            ..
        } => {
            login_recovery_key(
                &sessions,
                &pending_logins,
                &events,
                login_request_id,
                recovery_key,
            )
            .await
        }
        Request::VerifyDevice {
            account,
            recovery_key,
            ..
        } => verify_device(&sessions, &events, request_id, account, recovery_key).await,
        Request::Logout { account, .. } => logout(&sessions, &events, request_id, account).await,
        Request::ListState { .. } => list_state(&sessions, &events, request_id).await,
        Request::OpenRoom {
            account, room_id, ..
        } => open_room(&sessions, &events, request_id, account, room_id).await,
        Request::DownloadMedia {
            account, source, ..
        } => download_media(&sessions, &events, request_id, account, source).await,
        Request::SendMessage {
            account,
            room_id,
            body,
            ..
        } => send_message(&sessions, &events, request_id, account, room_id, body).await,
        Request::Quit { .. } => {
            for (_, session) in sessions.lock().await.drain() {
                if let Some(sync_task) = session.sync_task {
                    sync_task.abort();
                }
            }
            Ok(())
        }
    };

    if let Err(error) = result {
        send_error(
            &events,
            Some(request_id),
            "operation_failed",
            error.to_string(),
        )
        .await;
    }
}

async fn login(
    sessions: &SharedSessions,
    pending_logins: &SharedPendingLogins,
    events: &EventSender,
    request_id: u64,
    homeserver: String,
    username: String,
    password: String,
) -> Result<()> {
    let store_key = account_store_key(&homeserver, &username);
    if sessions
        .lock()
        .await
        .values()
        .any(|session| session.store_key == store_key)
        || pending_logins
            .lock()
            .await
            .values()
            .any(|pending| pending.store_key == store_key)
    {
        return Err(anyhow!("Matrix account is already logged in"));
    }
    let client = build_client_with_store(&homeserver, &store_key).await?;
    client
        .matrix_auth()
        .login_username(&username, &password)
        .initial_device_display_name("Fermium")
        .send()
        .await
        .context("Matrix password login failed")?;

    if client.encryption().secret_storage().is_enabled().await? {
        pending_logins.lock().await.insert(
            request_id,
            PendingLogin {
                client,
                homeserver,
                store_key,
            },
        );
        events
            .send(Event::LoginVerificationRequired {
                request_id,
                method: "recovery_key".to_owned(),
            })
            .await
            .context("sending login verification request")?;
        Ok(())
    } else {
        activate_session(
            sessions, events, request_id, client, homeserver, store_key, true,
        )
        .await
    }
}

async fn login_recovery_key(
    sessions: &SharedSessions,
    pending_logins: &SharedPendingLogins,
    events: &EventSender,
    login_request_id: u64,
    recovery_key: String,
) -> Result<()> {
    let pending = pending_logins
        .lock()
        .await
        .remove(&login_request_id)
        .ok_or_else(|| anyhow!("no login is waiting for device verification"))?;
    let PendingLogin {
        client,
        homeserver,
        store_key,
        ..
    } = pending;
    let result = recover_client(&client, recovery_key).await;

    if let Err(error) = result {
        pending_logins.lock().await.insert(
            login_request_id,
            PendingLogin {
                client,
                homeserver,
                store_key,
            },
        );
        return Err(error);
    }

    activate_session(
        sessions,
        events,
        login_request_id,
        client,
        homeserver,
        store_key,
        true,
    )
    .await
}

async fn verify_device(
    sessions: &SharedSessions,
    events: &EventSender,
    request_id: u64,
    account: String,
    recovery_key: String,
) -> Result<()> {
    let client = session_client(sessions, &account).await?;
    let active_account = client
        .user_id()
        .ok_or_else(|| anyhow!("active session has no account ID"))?
        .to_string();
    if active_account != account {
        return Err(anyhow!(
            "requested account {account} is not the active account"
        ));
    }
    recover_client(&client, recovery_key).await?;
    events
        .send(Event::DeviceVerified { request_id })
        .await
        .context("sending device verification response")?;
    Ok(())
}

async fn recover_client(client: &Client, mut recovery_key: String) -> Result<()> {
    let result = client.encryption().recovery().recover(&recovery_key).await;
    recovery_key.clear();
    result.context("Matrix recovery key verification failed")
}

async fn logout(
    sessions: &SharedSessions,
    events: &EventSender,
    request_id: u64,
    account: String,
) -> Result<()> {
    let client = session_client(sessions, &account).await?;
    client
        .matrix_auth()
        .logout()
        .await
        .context("Matrix logout failed")?;

    let session = sessions
        .lock()
        .await
        .remove(&account)
        .ok_or_else(|| anyhow!("Matrix account {account} is no longer logged in"))?;
    if let Some(sync_task) = session.sync_task {
        sync_task.abort();
    }

    let store_path = account_store_path(&session.store_key)?;
    if store_path.exists() {
        fs::remove_dir_all(&store_path)
            .with_context(|| format!("removing local Matrix store for account {account}"))?;
    }
    save_persisted_sessions(sessions).await?;

    events
        .send(Event::LogoutSucceeded {
            request_id,
            account,
        })
        .await
        .context("sending logout response")?;
    Ok(())
}

async fn list_state(
    sessions: &SharedSessions,
    events: &EventSender,
    request_id: u64,
) -> Result<()> {
    let clients: Vec<(String, String, Client, bool, ConnectionState)> = {
        let sessions = sessions.lock().await;
        let mut clients = Vec::with_capacity(sessions.len());
        for (user_id, session) in sessions.iter() {
            clients.push((
                user_id.clone(),
                session.client.homeserver().to_string(),
                session.client.clone(),
                session.initial_sync_complete.load(Ordering::Acquire),
                session.connection_state.lock().await.clone(),
            ));
        }
        clients
    };
    let mut clients = clients;
    clients.sort_by(|left, right| left.0.cmp(&right.0));
    let mut accounts = Vec::with_capacity(clients.len());
    for (user_id, homeserver, client, initial_sync_complete, connection_state) in clients {
        accounts.push(AccountSummary {
            user_id,
            homeserver,
            rooms: fast_room_summaries(&client),
            rooms_loading: !initial_sync_complete,
            connection_status: connection_state.status,
            last_sync_timestamp: connection_state.last_sync_timestamp,
            connection_error: connection_state.error,
        });
    }
    events
        .send(Event::State {
            request_id,
            accounts,
        })
        .await
        .context("sending state response")?;
    Ok(())
}

async fn open_room(
    sessions: &SharedSessions,
    events: &EventSender,
    request_id: u64,
    account: String,
    room_id: String,
) -> Result<()> {
    let client = session_client(sessions, &account).await?;
    let room_id = RoomId::parse(&room_id).context("room ID is invalid")?;
    let room = client
        .get_room(&room_id)
        .ok_or_else(|| anyhow!("room is not joined"))?;
    let room_summary = room_summary(&room).await;
    let messages = room
        .messages(MessagesOptions::backward())
        .await
        .context("loading room messages")?
        .chunk
        .iter()
        .filter_map(message_from_timeline)
        .collect();

    events
        .send(Event::RoomOpened {
            request_id,
            account,
            room: room_summary,
            messages,
        })
        .await
        .context("sending room response")?;
    Ok(())
}

async fn send_message(
    sessions: &SharedSessions,
    events: &EventSender,
    request_id: u64,
    account: String,
    room_id: String,
    body: String,
) -> Result<()> {
    if body.trim().is_empty() {
        return Err(anyhow!("message body cannot be empty"));
    }

    let client = session_client(sessions, &account).await?;
    let room_id = RoomId::parse(&room_id).context("room ID is invalid")?;
    let room = client
        .get_room(&room_id)
        .ok_or_else(|| anyhow!("room is not joined"))?;

    events
        .send(Event::MessagePending {
            request_id,
            account: account.clone(),
            room_id: room_id.to_string(),
            body: body.clone(),
        })
        .await
        .context("sending pending message event")?;
    let response = room
        .send(
            matrix_sdk::ruma::events::room::message::RoomMessageEventContent::text_plain(
                body.clone(),
            ),
        )
        .await
        .context("sending Matrix message")?;

    let sender = client
        .user_id()
        .ok_or_else(|| anyhow!("logged-in Matrix client has no user ID"))?
        .to_string();
    events
        .send(Event::Message {
            account: account.clone(),
            room_id: room_id.to_string(),
            message: MessageSummary {
                kind: MessageKind::Message,
                event_id: response.response.event_id.to_string(),
                sender,
                body,
                timestamp: current_timestamp_millis(),
                image: None,
            },
        })
        .await
        .context("sending local message event")?;
    events
        .send(Event::MessageSent {
            request_id,
            account,
            room_id: room_id.to_string(),
        })
        .await
        .context("sending message acknowledgement")?;
    Ok(())
}

async fn download_media(
    sessions: &SharedSessions,
    events: &EventSender,
    request_id: u64,
    account: String,
    source: serde_json::Value,
) -> Result<()> {
    let client = session_client(sessions, &account).await?;
    let source: MediaSource = serde_json::from_value(source).context("media source is invalid")?;
    let content = client
        .media()
        .get_media_content(
            &MediaRequestParameters {
                source,
                format: MediaFormat::File,
            },
            true,
        )
        .await
        .context("downloading media")?;

    events
        .send(Event::MediaDownloaded {
            request_id,
            data: BASE64.encode(content),
        })
        .await
        .context("sending downloaded media")?;
    Ok(())
}

async fn session_client(sessions: &SharedSessions, account: &str) -> Result<Client> {
    sessions
        .lock()
        .await
        .get(account)
        .map(|session| session.client.clone())
        .ok_or_else(|| anyhow!("Matrix account {account} is not logged in"))
}

fn fast_room_summaries(client: &Client) -> Vec<RoomSummary> {
    client
        .joined_rooms()
        .iter()
        .map(room_summary_fast)
        .collect()
}

fn room_summary_fast(room: &Room) -> RoomSummary {
    let info = room.clone_info();
    RoomSummary {
        room_id: room.room_id().to_string(),
        name: info
            .name()
            .map_or_else(|| room.room_id().to_string(), ToOwned::to_owned),
        is_dm: room.is_dm(),
        members: Vec::new(),
        visibility: "private".to_owned(),
        encryption: "disabled".to_owned(),
        has_unread: room_has_unread(room),
        last_activity_timestamp: room
            .latest_event_timestamp()
            .map(|timestamp| i64::from(timestamp.get()))
            .unwrap_or_default(),
        latest_message: None,
    }
}

async fn room_summary(room: &Room) -> RoomSummary {
    let info = room.clone_info();
    let is_dm = room.compute_is_dm().await.unwrap_or_else(|_| room.is_dm());
    let members = if is_dm {
        room_member_names(room).await
    } else {
        Vec::new()
    };
    let name = if members.is_empty() {
        info.name()
            .map_or_else(|| room.room_id().to_string(), ToOwned::to_owned)
    } else {
        members.join(", ")
    };
    let latest_message = room_latest_message(room).await;
    let last_activity_timestamp = room
        .latest_event_timestamp()
        .map(|timestamp| i64::from(timestamp.get()))
        .or_else(|| latest_message.as_ref().map(|message| message.timestamp))
        .unwrap_or_default();
    RoomSummary {
        room_id: room.room_id().to_string(),
        name,
        is_dm,
        members,
        visibility: "private".to_owned(),
        encryption: "disabled".to_owned(),
        has_unread: room_has_unread(room),
        last_activity_timestamp,
        latest_message,
    }
}

fn room_has_unread(room: &Room) -> bool {
    room.unread_notification_counts().notification_count > 0 || room.is_marked_unread()
}

async fn room_latest_message(room: &Room) -> Option<MessageSummary> {
    let messages = room.messages(MessagesOptions::backward()).await.ok()?;
    messages
        .chunk
        .iter()
        .filter_map(message_from_timeline)
        .max_by_key(|message| message.timestamp)
}

async fn room_member_names(room: &Room) -> Vec<String> {
    let mut names: Vec<String> = room
        .members_no_sync(RoomMemberships::JOIN)
        .await
        .unwrap_or_default()
        .into_iter()
        .filter(|member| !member.is_account_user())
        .map(|member| member.name().to_owned())
        .collect();

    if names.is_empty() {
        names = room
            .heroes()
            .into_iter()
            .filter(|hero| hero.user_id != room.own_user_id())
            .map(|hero| {
                hero.display_name
                    .unwrap_or_else(|| hero.user_id.localpart().to_owned())
            })
            .collect();
    }

    names.sort_unstable();
    names.dedup();
    names
}

async fn build_client_with_store(homeserver: &str, store_key: &str) -> Result<Client> {
    let homeserver_url = Url::parse(homeserver).context("homeserver must be a valid URL")?;
    let store_path = account_store_path(store_key)?;
    let parent = store_path
        .parent()
        .ok_or_else(|| anyhow!("Matrix store has no parent directory"))?;
    fs::create_dir_all(parent).context("creating Fermium data directory")?;
    let client = Client::builder()
        .homeserver_url(homeserver_url)
        .sqlite_store(store_path, None)
        .build()
        .await
        .context("building Matrix client")?;
    client
        .media()
        .set_media_retention_policy(default_media_retention_policy())
        .await
        .context("configuring media cache policy")?;
    Ok(client)
}

fn default_media_retention_policy() -> MediaRetentionPolicy {
    MediaRetentionPolicy::empty()
        .with_max_cache_size(Some(400 * 1024 * 1024))
        .with_max_file_size(Some(20 * 1024 * 1024))
        .with_last_access_expiry(Some(Duration::from_hours(60 * 24)))
        .with_cleanup_frequency(Some(Duration::from_hours(24)))
}

async fn activate_session(
    sessions: &SharedSessions,
    events: &EventSender,
    request_id: u64,
    client: Client,
    homeserver: String,
    store_key: String,
    persist: bool,
) -> Result<()> {
    let user_id = client
        .user_id()
        .ok_or_else(|| anyhow!("Matrix login did not return a user ID"))?
        .to_string();

    if sessions.lock().await.contains_key(&user_id) {
        return Err(anyhow!("Matrix account {user_id} is already logged in"));
    }

    let account = user_id.clone();

    let event_tx = events.clone();
    let event_account = account.clone();
    client.add_event_handler(move |event: Raw<AnySyncTimelineEvent>, room: Room| {
        let event_tx = event_tx.clone();
        let account = event_account.clone();
        async move {
            if room.state() == RoomState::Joined {
                let _ = event_tx
                    .send(Event::RoomUpdated {
                        account: account.clone(),
                        room: room_summary_fast(&room),
                    })
                    .await;
            } else {
                let _ = event_tx
                    .send(Event::RoomRemoved {
                        account: account.clone(),
                        room_id: room.room_id().to_string(),
                    })
                    .await;
            }

            if let Ok(event) = event.deserialize() {
                match event {
                    AnySyncTimelineEvent::MessageLike(AnySyncMessageLikeEvent::RoomMessage(
                        event,
                    )) => {
                        if let Some(event) = event.as_original()
                            && let Some(message) = message_from_original(event)
                        {
                            let _ = event_tx
                                .send(Event::Message {
                                    account,
                                    room_id: room.room_id().to_string(),
                                    message,
                                })
                                .await;
                        }
                    }
                    AnySyncTimelineEvent::State(event) => {
                        if let Some(message) = channel_event_from_state(event) {
                            let _ = event_tx
                                .send(Event::Message {
                                    account,
                                    room_id: room.room_id().to_string(),
                                    message,
                                })
                                .await;
                        }
                    }
                    _ => {}
                }
            }
        }
    });

    if persist {
        client
            .matrix_auth()
            .session()
            .ok_or_else(|| anyhow!("Matrix login did not return a session"))?;
    }

    let initial_sync_complete = Arc::new(AtomicBool::new(false));
    let connection_state = Arc::new(Mutex::new(ConnectionState::default()));

    sessions.lock().await.insert(
        account.clone(),
        Session {
            client: client.clone(),
            sync_task: None,
            store_key,
            initial_sync_complete: Arc::clone(&initial_sync_complete),
            connection_state: Arc::clone(&connection_state),
        },
    );

    if persist && let Err(error) = save_persisted_sessions(sessions).await {
        if let Some(session) = sessions.lock().await.remove(&account) {
            if let Some(sync_task) = session.sync_task {
                sync_task.abort();
            }
        }
        return Err(error);
    }

    let rooms = fast_room_summaries(&client);
    if request_id == 0 {
        events
            .send(Event::AccountAvailable {
                account: AccountSummary {
                    user_id: account.clone(),
                    homeserver: homeserver.clone(),
                    rooms,
                    rooms_loading: true,
                    connection_status: None,
                    last_sync_timestamp: None,
                    connection_error: None,
                },
            })
            .await
            .context("sending restored account event")?;
    } else {
        events
            .send(Event::LoginSucceeded {
                request_id,
                user_id: account.clone(),
                homeserver,
                rooms,
                rooms_loading: true,
                connection_status: None,
                last_sync_timestamp: None,
                connection_error: None,
            })
            .await
            .context("sending login response")?;
    }

    let sync_task = tokio::spawn(sync_forever(
        client,
        events.clone(),
        account.clone(),
        initial_sync_complete,
        connection_state,
    ));
    if let Some(session) = sessions.lock().await.get_mut(&account) {
        session.sync_task = Some(sync_task);
    }

    Ok(())
}

async fn send_fast_room_summaries(client: &Client, events: &EventSender, account: &str) {
    for room in client.joined_rooms() {
        let _ = events
            .send(Event::RoomUpdated {
                account: account.to_owned(),
                room: room_summary_fast(&room),
            })
            .await;
    }
}

fn spawn_room_enrichment(client: &Client, events: &EventSender, account: &str) {
    for room in client.joined_rooms() {
        let events = events.clone();
        let account = account.to_owned();
        tokio::spawn(async move {
            let room = room_summary(&room).await;
            let _ = events.send(Event::RoomUpdated { account, room }).await;
        });
    }
}

async fn sync_forever(
    client: Client,
    events: EventSender,
    account: String,
    initial_sync_complete: Arc<AtomicBool>,
    connection_state: Arc<Mutex<ConnectionState>>,
) {
    // `Client::sync` returns on the first error.  Consume errors in the
    // callback instead so the SDK's sync stream can retry after a temporary
    // network outage, such as the connection loss caused by system sleep.
    send_fast_room_summaries(&client, &events, &account).await;

    let initial_result = client.sync_once(SyncSettings::default()).await;
    let initial_ok = initial_result.is_ok();
    if let Err(error) = initial_result {
        let error = error.to_string();
        send_error(&events, None, "sync_failed", error.clone()).await;
        fermium_set_connection_status(
            &events,
            &connection_state,
            &account,
            ConnectionStatus::Offline,
            None,
            Some(error),
        )
        .await;
    } else {
        initial_sync_complete.store(true, Ordering::Release);
        send_fast_room_summaries(&client, &events, &account).await;
        spawn_room_enrichment(&client, &events, &account);
        fermium_set_connection_status(
            &events,
            &connection_state,
            &account,
            ConnectionStatus::Online,
            Some(current_timestamp_millis()),
            None,
        )
        .await;
    }

    let online = Arc::new(AtomicBool::new(initial_ok));
    let callback_account = account.clone();
    let callback_client = client.clone();
    let callback_initial_sync_complete = Arc::clone(&initial_sync_complete);
    let result = client
        .sync_with_result_callback(SyncSettings::default(), |result| {
            let events = events.clone();
            let online = Arc::clone(&online);
            let account = callback_account.clone();
            let client = callback_client.clone();
            let initial_sync_complete = Arc::clone(&callback_initial_sync_complete);
            let connection_state = Arc::clone(&connection_state);
            async move {
                match result {
                    Ok(_) => {
                        if !initial_sync_complete.swap(true, Ordering::AcqRel) {
                            send_fast_room_summaries(&client, &events, &account).await;
                            spawn_room_enrichment(&client, &events, &account);
                        }
                        online.store(true, Ordering::Release);
                        fermium_set_connection_status(
                            &events,
                            &connection_state,
                            &account,
                            ConnectionStatus::Online,
                            Some(current_timestamp_millis()),
                            None,
                        )
                        .await;
                    }
                    Err(error) => {
                        let error = error.to_string();
                        if online.swap(false, Ordering::AcqRel) {
                            send_error(&events, None, "sync_failed", error.clone()).await;
                        }
                        fermium_set_connection_status(
                            &events,
                            &connection_state,
                            &account,
                            ConnectionStatus::Offline,
                            None,
                            Some(error),
                        )
                        .await;
                    }
                }

                Ok(LoopCtrl::Continue)
            }
        })
        .await;

    if let Err(error) = result {
        let error = error.to_string();
        send_error(&events, None, "sync_stopped", error.clone()).await;
        fermium_set_connection_status(
            &events,
            &connection_state,
            &account,
            ConnectionStatus::Offline,
            None,
            Some(error),
        )
        .await;
    }
}

async fn fermium_set_connection_status(
    events: &EventSender,
    connection_state: &Arc<Mutex<ConnectionState>>,
    account: &str,
    status: ConnectionStatus,
    last_sync_timestamp: Option<i64>,
    error: Option<String>,
) {
    let last_sync_timestamp = {
        let mut state = connection_state.lock().await;
        state.status = Some(status.clone());
        if let Some(timestamp) = last_sync_timestamp {
            state.last_sync_timestamp = Some(timestamp);
        }
        state.error = error.clone();
        state.last_sync_timestamp
    };
    let _ = events
        .send(Event::ConnectionStatus {
            account: account.to_owned(),
            status,
            last_sync_timestamp,
            error,
        })
        .await;
}

fn restore_persisted_sessions(sessions: &SharedSessions, events: &EventSender) {
    let stored_sessions = match load_persisted_sessions() {
        Ok(stored_sessions) => stored_sessions,
        Err(error) => {
            let events = events.clone();
            tokio::spawn(async move {
                send_error(&events, None, "session_load_failed", error.to_string()).await;
            });
            return;
        }
    };

    for stored in stored_sessions {
        let homeserver = stored.homeserver.clone();
        let store_key = stored.store_key.clone();
        let sessions = Arc::clone(sessions);
        let events = events.clone();
        tokio::spawn(async move {
            let result = async {
                let client = build_client_with_store(&homeserver, &store_key).await?;
                client.restore_session(stored.session).await?;
                activate_session(&sessions, &events, 0, client, homeserver, store_key, false).await
            }
            .await;
            if let Err(error) = result {
                send_error(&events, None, "session_restore_failed", error.to_string()).await;
            }
        });
    }
}

fn fermium_data_dir() -> Result<PathBuf> {
    dirs::data_dir()
        .map(|path| path.join("fermium"))
        .ok_or_else(|| anyhow!("could not determine a data directory for Fermium"))
}

fn persisted_session_path() -> Result<PathBuf> {
    Ok(fermium_data_dir()?.join("sessions.json"))
}

fn account_store_key(homeserver: &str, username: &str) -> String {
    let mut key = String::with_capacity((homeserver.len() + username.len()) * 2 + 2);
    for byte in format!("{homeserver}\n{username}").bytes() {
        let _ = write!(key, "{byte:02x}");
    }
    key
}

fn account_store_path(store_key: &str) -> Result<PathBuf> {
    Ok(fermium_data_dir()?.join(format!("matrix-store-{store_key}")))
}

fn load_persisted_sessions() -> Result<Vec<StoredSession>> {
    let path = persisted_session_path()?;
    if !path.exists() {
        return Ok(Vec::new());
    }

    let contents = fs::read_to_string(&path).context("reading persisted Matrix sessions")?;
    serde_json::from_str(&contents).context("decoding persisted Matrix sessions")
}

async fn save_persisted_sessions(sessions: &SharedSessions) -> Result<()> {
    let stored_sessions = {
        let sessions = sessions.lock().await;
        let mut stored_sessions = Vec::with_capacity(sessions.len());
        for (user_id, session) in sessions.iter() {
            let matrix_session = session
                .client
                .matrix_auth()
                .session()
                .ok_or_else(|| anyhow!("Matrix account {user_id} has no session"))?;
            stored_sessions.push(StoredSession {
                user_id: user_id.clone(),
                homeserver: session.client.homeserver().to_string(),
                store_key: session.store_key.clone(),
                session: matrix_session,
            });
        }
        stored_sessions.sort_by(|left, right| left.user_id.cmp(&right.user_id));
        stored_sessions
    };

    let path = persisted_session_path()?;
    let parent = path
        .parent()
        .ok_or_else(|| anyhow!("persisted Matrix session has no parent directory"))?;
    fs::create_dir_all(parent).context("creating Fermium data directory")?;

    let temporary_path = path.with_extension("json.tmp");
    let contents =
        serde_json::to_vec_pretty(&stored_sessions).context("encoding Matrix sessions")?;
    let mut options = OpenOptions::new();
    options.create(true).write(true).truncate(true);
    #[cfg(unix)]
    std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
    let mut file = options
        .open(&temporary_path)
        .context("opening persisted Matrix sessions")?;
    file.write_all(&contents)
        .context("writing persisted Matrix sessions")?;
    file.sync_all()
        .context("flushing persisted Matrix sessions")?;
    fs::rename(&temporary_path, &path).context("installing persisted Matrix sessions")?;
    Ok(())
}

fn message_from_timeline(event: &TimelineEvent) -> Option<MessageSummary> {
    let event: AnySyncTimelineEvent = event.raw().deserialize().ok()?;
    match event {
        AnySyncTimelineEvent::MessageLike(AnySyncMessageLikeEvent::RoomMessage(event)) => {
            message_from_original(event.as_original()?)
        }
        AnySyncTimelineEvent::State(event) => channel_event_from_state(event),
        AnySyncTimelineEvent::MessageLike(_) => None,
    }
}

fn message_from_original(event: &OriginalSyncRoomMessageEvent) -> Option<MessageSummary> {
    let (kind, body, image) = match &event.content.msgtype {
        MessageType::Text(text) => (MessageKind::Message, text.body.clone(), None),
        MessageType::Notice(notice) => (MessageKind::Message, notice.body.clone(), None),
        MessageType::Emote(emote) => (MessageKind::Message, emote.body.clone(), None),
        MessageType::Image(image) => {
            let info = image.info.as_deref();
            let source = serde_json::to_value(&image.source).ok()?;
            (
                MessageKind::Image,
                image.body.clone(),
                Some(ImageSummary {
                    source,
                    width: info.and_then(|info| info.width.map(u64::from)),
                    height: info.and_then(|info| info.height.map(u64::from)),
                    mimetype: info.and_then(|info| info.mimetype.clone()),
                }),
            )
        }
        _ => return None,
    };
    Some(MessageSummary {
        kind,
        event_id: event.event_id.to_string(),
        sender: event.sender.to_string(),
        body,
        timestamp: event
            .origin_server_ts
            .get()
            .to_string()
            .parse()
            .unwrap_or_default(),
        image,
    })
}

fn channel_event_from_state(
    event: matrix_sdk::ruma::events::AnySyncStateEvent,
) -> Option<MessageSummary> {
    use matrix_sdk::ruma::events::AnySyncStateEvent;

    match event {
        AnySyncStateEvent::RoomMember(event) => channel_event_from_member(event.as_original()?),
        AnySyncStateEvent::RoomName(event) => {
            let event = event.as_original()?;
            Some(channel_event(
                event.event_id.to_string(),
                format!("Room name changed to {}", event.content.name),
                event.origin_server_ts.get().into(),
            ))
        }
        AnySyncStateEvent::RoomTopic(event) => {
            let event = event.as_original()?;
            Some(channel_event(
                event.event_id.to_string(),
                format!("Room topic changed to {}", event.content.topic),
                event.origin_server_ts.get().into(),
            ))
        }
        AnySyncStateEvent::RoomAvatar(event) => {
            let event = event.as_original()?;
            Some(channel_event(
                event.event_id.to_string(),
                "Room profile picture changed".to_owned(),
                event.origin_server_ts.get().into(),
            ))
        }
        AnySyncStateEvent::RoomCanonicalAlias(event) => {
            let event = event.as_original()?;
            Some(channel_event(
                event.event_id.to_string(),
                "Room alias changed".to_owned(),
                event.origin_server_ts.get().into(),
            ))
        }
        AnySyncStateEvent::RoomEncryption(event) => {
            let event = event.as_original()?;
            Some(channel_event(
                event.event_id.to_string(),
                "Room encryption settings changed".to_owned(),
                event.origin_server_ts.get().into(),
            ))
        }
        AnySyncStateEvent::RoomPowerLevels(event) => {
            let event = event.as_original()?;
            Some(channel_event(
                event.event_id.to_string(),
                "Room permissions changed".to_owned(),
                event.origin_server_ts.get().into(),
            ))
        }
        AnySyncStateEvent::RoomJoinRules(event) => {
            let event = event.as_original()?;
            Some(channel_event(
                event.event_id.to_string(),
                "Room join rules changed".to_owned(),
                event.origin_server_ts.get().into(),
            ))
        }
        AnySyncStateEvent::RoomHistoryVisibility(event) => {
            let event = event.as_original()?;
            Some(channel_event(
                event.event_id.to_string(),
                "Room history visibility changed".to_owned(),
                event.origin_server_ts.get().into(),
            ))
        }
        AnySyncStateEvent::RoomGuestAccess(event) => {
            let event = event.as_original()?;
            Some(channel_event(
                event.event_id.to_string(),
                "Room guest access changed".to_owned(),
                event.origin_server_ts.get().into(),
            ))
        }
        _ => None,
    }
}

fn channel_event_from_member(
    event: &matrix_sdk::ruma::events::room::member::OriginalSyncRoomMemberEvent,
) -> Option<MessageSummary> {
    let name = event
        .content
        .displayname
        .as_deref()
        .unwrap_or_else(|| event.state_key.localpart());
    let current_membership = event.content.membership.to_string();
    let previous = event.prev_content();
    let membership_changed =
        previous.is_none_or(|previous| previous.membership.to_string() != current_membership);

    let body = if membership_changed {
        match current_membership.as_str() {
            "join" => format!("{name} joined"),
            "leave" => format!("{name} left"),
            "ban" => format!("{name} was banned"),
            "invite" => format!("{name} was invited"),
            "knock" => format!("{name} requested to join"),
            _ => return None,
        }
    } else {
        let previous = previous?;
        let name_changed = previous.displayname != event.content.displayname;
        let avatar_changed = previous.avatar_url != event.content.avatar_url;
        match (name_changed, avatar_changed) {
            (true, true) => {
                format!("{name} changed their name and changed their profile picture")
            }
            (true, false) => format!("{name} changed their name"),
            (false, true) => format!("{name} changed their profile picture"),
            (false, false) => return None,
        }
    };

    Some(channel_event(
        event.event_id.to_string(),
        body,
        event.origin_server_ts.get().into(),
    ))
}

fn channel_event(event_id: String, body: String, timestamp: i64) -> MessageSummary {
    MessageSummary {
        kind: MessageKind::ChannelEvent,
        event_id,
        sender: String::new(),
        body,
        timestamp,
        image: None,
    }
}

fn current_timestamp_millis() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .ok()
        .and_then(|duration| i64::try_from(duration.as_millis()).ok())
        .unwrap_or_default()
}

async fn send_error(events: &EventSender, request_id: Option<u64>, code: &str, message: String) {
    let _ = events
        .send(Event::Error {
            request_id,
            code: code.to_owned(),
            message,
        })
        .await;
}
