//! Protocol and domain values shared by the Fermium helper and Emacs client.

use serde::{Deserialize, Serialize};

pub const PROTOCOL_VERSION: u32 = 1;

#[derive(Deserialize, Serialize)]
#[serde(tag = "command", rename_all = "snake_case")]
pub enum Request {
    Login {
        request_id: u64,
        homeserver: String,
        username: String,
        #[serde(skip_serializing)]
        password: String,
    },
    LoginRecoveryKey {
        request_id: u64,
        login_request_id: u64,
        #[serde(skip_serializing)]
        recovery_key: String,
    },
    VerifyDevice {
        request_id: u64,
        account: String,
        #[serde(skip_serializing)]
        recovery_key: String,
    },
    Logout {
        request_id: u64,
        account: String,
    },
    ListState {
        request_id: u64,
    },
    OpenRoom {
        request_id: u64,
        account: String,
        room_id: String,
    },
    DownloadMedia {
        request_id: u64,
        account: String,
        source: serde_json::Value,
    },
    SendMessage {
        request_id: u64,
        account: String,
        room_id: String,
        body: String,
    },
    Quit {
        request_id: u64,
    },
}

impl Request {
    #[must_use]
    pub fn request_id(&self) -> u64 {
        match self {
            Self::Login { request_id, .. }
            | Self::LoginRecoveryKey { request_id, .. }
            | Self::VerifyDevice { request_id, .. }
            | Self::Logout { request_id, .. }
            | Self::ListState { request_id }
            | Self::OpenRoom { request_id, .. }
            | Self::DownloadMedia { request_id, .. }
            | Self::SendMessage { request_id, .. }
            | Self::Quit { request_id } => *request_id,
        }
    }
}

#[derive(Clone, Debug, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Event {
    Ready {
        protocol_version: u32,
    },
    LoginSucceeded {
        request_id: u64,
        user_id: String,
        homeserver: String,
        rooms: Vec<RoomSummary>,
        rooms_loading: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        connection_status: Option<ConnectionStatus>,
        #[serde(skip_serializing_if = "Option::is_none")]
        last_sync_timestamp: Option<i64>,
        #[serde(skip_serializing_if = "Option::is_none")]
        connection_error: Option<String>,
    },
    AccountAvailable {
        account: AccountSummary,
    },
    LoginVerificationRequired {
        request_id: u64,
        method: String,
    },
    DeviceVerified {
        request_id: u64,
    },
    LogoutSucceeded {
        request_id: u64,
        account: String,
    },
    State {
        request_id: u64,
        accounts: Vec<AccountSummary>,
    },
    RoomOpened {
        request_id: u64,
        account: String,
        room: RoomSummary,
        messages: Vec<MessageSummary>,
    },
    RoomUpdated {
        account: String,
        room: RoomSummary,
    },
    RoomRemoved {
        account: String,
        room_id: String,
    },
    MediaDownloaded {
        request_id: u64,
        data: String,
    },
    Message {
        account: String,
        room_id: String,
        message: MessageSummary,
    },
    MessagePending {
        request_id: u64,
        account: String,
        room_id: String,
        body: String,
    },
    MessageSent {
        request_id: u64,
        account: String,
        room_id: String,
    },
    ConnectionStatus {
        account: String,
        status: ConnectionStatus,
        #[serde(skip_serializing_if = "Option::is_none")]
        last_sync_timestamp: Option<i64>,
        #[serde(skip_serializing_if = "Option::is_none")]
        error: Option<String>,
    },
    Error {
        request_id: Option<u64>,
        code: String,
        message: String,
    },
}

#[derive(Clone, Debug, Serialize)]
pub struct AccountSummary {
    pub user_id: String,
    pub homeserver: String,
    pub rooms: Vec<RoomSummary>,
    pub rooms_loading: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub connection_status: Option<ConnectionStatus>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_sync_timestamp: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub connection_error: Option<String>,
}

#[derive(Clone, Debug, Serialize)]
pub struct RoomSummary {
    pub room_id: String,
    pub name: String,
    pub is_dm: bool,
    pub members: Vec<String>,
    pub visibility: String,
    pub encryption: String,
    pub has_unread: bool,
    pub last_activity_timestamp: i64,
    pub latest_message: Option<MessageSummary>,
}

#[derive(Clone, Debug, Serialize)]
pub struct MessageSummary {
    pub kind: MessageKind,
    pub event_id: String,
    pub sender: String,
    pub body: String,
    pub timestamp: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub image: Option<ImageSummary>,
}

#[derive(Clone, Debug, Serialize)]
pub struct ImageSummary {
    pub source: serde_json::Value,
    pub width: Option<u64>,
    pub height: Option<u64>,
    pub mimetype: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum MessageKind {
    Message,
    Image,
    ChannelEvent,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum ConnectionStatus {
    Online,
    Offline,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn protocol_decodes_login_without_serializing_the_password() {
        let request: Request = serde_json::from_str(
            r#"{"command":"login","request_id":7,"homeserver":"https://example.org","username":"@alice:example.org","password":"secret"}"#,
        )
        .expect("login request should decode");

        assert_eq!(request.request_id(), 7);
        let encoded = serde_json::to_string(&request).expect("request metadata should encode");
        assert!(!encoded.contains("secret"));
        assert!(encoded.contains("https://example.org"));
    }

    #[test]
    fn protocol_decodes_login_recovery_key_without_serializing_the_key() {
        let request: Request = serde_json::from_str(
            r#"{"command":"login_recovery_key","request_id":8,"login_request_id":7,"recovery_key":"secret"}"#,
        )
        .expect("login recovery key request should decode");

        assert_eq!(request.request_id(), 8);
        let encoded = serde_json::to_string(&request).expect("request metadata should encode");
        assert!(!encoded.contains("secret"));
        assert!(encoded.contains("\"login_request_id\":7"));
    }

    #[test]
    fn protocol_decodes_verify_device_without_serializing_the_key() {
        let request: Request = serde_json::from_str(
            r#"{"command":"verify_device","request_id":12,"account":"@alice:example.org","recovery_key":"secret"}"#,
        )
        .expect("device verification request should decode");

        assert_eq!(request.request_id(), 12);
        let encoded = serde_json::to_string(&request).expect("request metadata should encode");
        assert!(!encoded.contains("secret"));
        assert!(encoded.contains("@alice:example.org"));
    }

    #[test]
    fn protocol_decodes_logout_for_a_specific_account() {
        let request: Request = serde_json::from_str(
            r#"{"command":"logout","request_id":13,"account":"@alice:example.org"}"#,
        )
        .expect("logout request should decode");

        assert_eq!(request.request_id(), 13);
        let encoded = serde_json::to_string(&request).expect("logout request should encode");
        assert!(encoded.contains("@alice:example.org"));
    }

    #[test]
    fn login_verification_event_is_line_protocol_friendly() {
        let event = Event::LoginVerificationRequired {
            request_id: 7,
            method: "recovery_key".to_owned(),
        };
        let encoded = serde_json::to_string(&event).expect("event should encode");
        assert_eq!(
            encoded,
            r#"{"type":"login_verification_required","request_id":7,"method":"recovery_key"}"#
        );
    }

    #[test]
    fn device_verified_event_is_line_protocol_friendly() {
        let event = Event::DeviceVerified { request_id: 11 };
        let encoded = serde_json::to_string(&event).expect("event should encode");
        assert_eq!(encoded, r#"{"type":"device_verified","request_id":11}"#);
    }

    #[test]
    fn event_serialization_is_line_protocol_friendly() {
        let event = Event::ConnectionStatus {
            account: "@alice:example.org".to_owned(),
            status: ConnectionStatus::Online,
            last_sync_timestamp: None,
            error: None,
        };
        let encoded = serde_json::to_string(&event).expect("event should encode");
        assert_eq!(
            encoded,
            r#"{"type":"connection_status","account":"@alice:example.org","status":"online"}"#
        );
    }

    #[test]
    fn connection_status_serializes_sync_metadata() {
        let event = Event::ConnectionStatus {
            account: "@alice:example.org".to_owned(),
            status: ConnectionStatus::Offline,
            last_sync_timestamp: Some(1_000),
            error: Some("network timeout".to_owned()),
        };
        let encoded = serde_json::to_string(&event).expect("event should encode");
        assert_eq!(
            encoded,
            r#"{"type":"connection_status","account":"@alice:example.org","status":"offline","last_sync_timestamp":1000,"error":"network timeout"}"#
        );
    }

    #[test]
    fn download_media_request_has_a_request_id() {
        let request: Request = serde_json::from_str(
            r#"{"command":"download_media","request_id":9,"account":"@alice:example.org","source":{"url":"mxc://example.org/image"}}"#,
        )
        .expect("media request should decode");

        assert_eq!(request.request_id(), 9);
    }

    #[test]
    fn protocol_serializes_incremental_account_and_room_events() {
        let room = RoomSummary {
            room_id: "!room:example.org".to_owned(),
            name: "Example room".to_owned(),
            is_dm: false,
            members: Vec::new(),
            visibility: "private".to_owned(),
            encryption: "disabled".to_owned(),
            has_unread: false,
            last_activity_timestamp: 0,
            latest_message: None,
        };
        let account = AccountSummary {
            user_id: "@alice:example.org".to_owned(),
            homeserver: "https://example.org".to_owned(),
            rooms: vec![room.clone()],
            rooms_loading: true,
            connection_status: None,
            last_sync_timestamp: None,
            connection_error: None,
        };

        let account_event = serde_json::to_string(&Event::AccountAvailable { account })
            .expect("account event should encode");
        assert!(account_event.contains("\"type\":\"account_available\""));
        assert!(account_event.contains("\"rooms_loading\":true"));

        let room_event = serde_json::to_string(&Event::RoomUpdated {
            account: "@alice:example.org".to_owned(),
            room,
        })
        .expect("room event should encode");
        assert!(room_event.contains("\"type\":\"room_updated\""));
        assert!(room_event.contains("!room:example.org"));
    }
}
