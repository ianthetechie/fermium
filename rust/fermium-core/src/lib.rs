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
    ListState {
        request_id: u64,
    },
    OpenRoom {
        request_id: u64,
        room_id: String,
    },
    SendMessage {
        request_id: u64,
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
            | Self::ListState { request_id }
            | Self::OpenRoom { request_id, .. }
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
    },
    State {
        request_id: u64,
        user_id: String,
        rooms: Vec<RoomSummary>,
    },
    RoomOpened {
        request_id: u64,
        room: RoomSummary,
        messages: Vec<MessageSummary>,
    },
    Message {
        room_id: String,
        message: MessageSummary,
    },
    MessagePending {
        request_id: u64,
        room_id: String,
        body: String,
    },
    MessageSent {
        request_id: u64,
        room_id: String,
    },
    ConnectionStatus {
        status: ConnectionStatus,
    },
    Error {
        request_id: Option<u64>,
        code: String,
        message: String,
    },
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
}

#[derive(Clone, Debug, Serialize)]
pub struct MessageSummary {
    pub sender: String,
    pub body: String,
    pub timestamp: i64,
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
    fn event_serialization_is_line_protocol_friendly() {
        let event = Event::ConnectionStatus {
            status: ConnectionStatus::Online,
        };
        let encoded = serde_json::to_string(&event).expect("event should encode");
        assert_eq!(encoded, r#"{"type":"connection_status","status":"online"}"#);
    }
}
