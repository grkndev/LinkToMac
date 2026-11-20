//! The first varint of every data stream names its channel (plan "Kanallar"; the Swift and Kotlin twins and this one all run the
//! `channels` section of `protocol-vectors/quic-control.json`): 1 file (bidirectional), 2 screen and 3 camera (unidirectional).

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum QuicChannel {
    File,
    Screen,
    Camera,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ChannelParse {
    Known(QuicChannel, usize),
    /// A well-formed varint that names no channel we know.
    Unknown(u64, usize),
    NeedMoreBytes,
}

impl QuicChannel {
    pub fn type_id(self) -> u64 {
        match self {
            Self::File => 1,
            Self::Screen => 2,
            Self::Camera => 3,
        }
    }

    pub fn from_type_id(id: u64) -> Option<Self> {
        match id {
            1 => Some(Self::File),
            2 => Some(Self::Screen),
            3 => Some(Self::Camera),
            _ => None,
        }
    }

    pub fn is_bidirectional(self) -> bool {
        self == Self::File
    }

    /// What a sender writes first: the shortest varint (all three ids fit one byte).
    pub fn header(self) -> Vec<u8> {
        vec![self.type_id() as u8]
    }

    /// Reads the FIRST varint of `bytes` (RFC 9000 §16: the top two bits give a length of 1, 2, 4 or 8 bytes). A longer-than-necessary
    /// form is accepted; anything after the varint is left alone.
    pub fn parse(bytes: &[u8]) -> ChannelParse {
        let Some(&first) = bytes.first() else { return ChannelParse::NeedMoreBytes };
        let length = 1usize << (first >> 6);
        if bytes.len() < length {
            return ChannelParse::NeedMoreBytes;
        }
        let mut value = u64::from(first & 0x3f);
        for &b in &bytes[1..length] {
            value = (value << 8) | u64::from(b);
        }
        match Self::from_type_id(value) {
            Some(channel) => ChannelParse::Known(channel, length),
            None => ChannelParse::Unknown(value, length),
        }
    }
}
