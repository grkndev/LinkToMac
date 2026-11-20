//! JNI layer of the QUIC client (stage 1.7). It only TRANSLATES `client.rs`: Kotlin calls become commands, client events become calls on
//! a Kotlin `QuicEvents` object. No rule lives here, because this is the one layer that cannot be tested on the host (it needs a JVM);
//! the registry below and the translation tables are the only parts with any logic and those are unit-tested.
//!
//! Rules of this file: every entry point is wrapped in `catch_unwind` (a panic must never unwind into the JVM); an exception that a Kotlin
//! callback throws is cleared and dropped; nothing but fixed texts and numbers is returned; no address, port, fingerprint or token is
//! ever formatted anywhere.
//!
//! Return conventions (Kotlin `QuicCore` mirrors them): `nativeConnect` gives a handle > 0 or a negative [`ConnectFailure`]; `nativeOpenUni`
//! a stream id > 0 or the negative of an [`ErrorCode`] number; booleans say whether the command was queued.

use std::collections::HashMap;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::{Arc, LazyLock, Mutex, OnceLock};

use jni::objects::{GlobalRef, JByteArray, JClass, JObject, JString, JValue};
use jni::sys::{jboolean, jint, jlong, JNI_FALSE, JNI_TRUE};
use jni::{JNIEnv, JavaVM};

use crate::channel::QuicChannel;
use crate::client::{Client, Event, EventSink, Stats, Timeouts};
use crate::error::ErrorCode;
use crate::params::{ConnectParams, ParamError};

/// Why `nativeConnect` returned no handle (negative values).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConnectFailure {
    Host = -1,
    Port = -2,
    Fingerprint = -3,
    Token = -4,
    Internal = -5,
}

impl From<ParamError> for ConnectFailure {
    fn from(error: ParamError) -> Self {
        match error {
            ParamError::Host => Self::Host,
            ParamError::Port => Self::Port,
            ParamError::Fingerprint => Self::Fingerprint,
            ParamError::Token => Self::Token,
        }
    }
}

/// Handle table: Kotlin holds a plain number, never a pointer, so a stale or invented handle is a lookup miss and not a crash.
pub struct Registry<T> {
    next: AtomicI64,
    items: Mutex<HashMap<i64, Arc<T>>>,
}

impl<T> Registry<T> {
    pub fn new() -> Self {
        Self { next: AtomicI64::new(1), items: Mutex::new(HashMap::new()) }
    }

    pub fn insert(&self, item: T) -> i64 {
        let handle = self.next.fetch_add(1, Ordering::SeqCst);
        if let Ok(mut items) = self.items.lock() {
            items.insert(handle, Arc::new(item));
        }
        handle
    }

    pub fn get(&self, handle: i64) -> Option<Arc<T>> {
        self.items.lock().ok()?.get(&handle).cloned()
    }

    pub fn remove(&self, handle: i64) -> Option<Arc<T>> {
        self.items.lock().ok()?.remove(&handle)
    }

    pub fn len(&self) -> usize {
        self.items.lock().map(|items| items.len()).unwrap_or(0)
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

impl<T> Default for Registry<T> {
    fn default() -> Self {
        Self::new()
    }
}

static CLIENTS: LazyLock<Registry<Client>> = LazyLock::new(Registry::new);
static VM: OnceLock<JavaVM> = OnceLock::new();

/// Events go to Kotlin on the client's own thread, in order; the Kotlin side hands them to its single executor.
struct JniSink {
    vm: JavaVM,
    events: GlobalRef,
}

impl JniSink {
    fn call(&self, name: &str, signature: &str, build: impl for<'a> FnOnce(&mut JNIEnv<'a>) -> Option<Vec<JValueOwned<'a>>>) {
        // The client thread lives for the whole session: attach it once and for good instead of once per event.
        let Ok(mut env) = self.vm.attach_current_thread_permanently() else { return };
        let _ = env.with_local_frame(16, |env| -> jni::errors::Result<()> {
            let Some(owned) = build(env) else { return Ok(()) };
            let args: Vec<JValue> = owned.iter().map(JValueOwned::as_value).collect();
            let _ = env.call_method(&self.events, name, signature, &args);
            // A Kotlin callback that throws must not poison the thread: drop the exception, keep delivering.
            if env.exception_check().unwrap_or(false) {
                let _ = env.exception_clear();
            }
            Ok(())
        });
    }
}

/// Owns the objects/values an event call needs while the local frame is open.
enum JValueOwned<'a> {
    Int(jint),
    Long(jlong),
    Bool(jboolean),
    Object(JObject<'a>),
}

impl JValueOwned<'_> {
    fn as_value(&self) -> JValue<'_, '_> {
        match self {
            JValueOwned::Int(v) => JValue::Int(*v),
            JValueOwned::Long(v) => JValue::Long(*v),
            JValueOwned::Bool(v) => JValue::Bool(*v),
            JValueOwned::Object(o) => JValue::Object(o),
        }
    }
}

impl EventSink for JniSink {
    fn event(&self, event: Event) {
        let result = catch_unwind(AssertUnwindSafe(|| self.deliver(event)));
        let _ = result; // a panic in delivery drops that one event; the client thread keeps running
    }
}

impl JniSink {
    fn deliver(&self, event: Event) {
        match event {
            Event::Connected => self.call("onConnected", "()V", |_| Some(vec![])),
            Event::Failed(code) => self.call("onFailed", "(I)V", |_| Some(vec![JValueOwned::Int(code.as_i32())])),
            Event::SessionLine(line) => self.call("onSessionLine", "(Ljava/lang/String;)V", |env| {
                let text = env.new_string(&line).ok()?;
                Some(vec![JValueOwned::Object(text.into())])
            }),
            Event::PeerEnded => self.call("onPeerEnded", "()V", |_| Some(vec![])),
            Event::Datagram(bytes) => self.call("onDatagram", "([B)V", |env| {
                let array = env.byte_array_from_slice(&bytes).ok()?;
                Some(vec![JValueOwned::Object(array.into())])
            }),
            Event::UniStream { id, channel } => self.call("onUniStream", "(JI)V", |_| {
                Some(vec![JValueOwned::Long(id as jlong), JValueOwned::Int(channel.type_id() as jint)])
            }),
            Event::StreamData { id, bytes, fin } => self.call("onStreamData", "(J[BZ)V", |env| {
                let array = env.byte_array_from_slice(&bytes).ok()?;
                Some(vec![
                    JValueOwned::Long(id as jlong),
                    JValueOwned::Object(array.into()),
                    JValueOwned::Bool(if fin { JNI_TRUE } else { JNI_FALSE }),
                ])
            }),
            Event::Stats(Stats { rtt_ms, cwnd, lost_packets, congestion_events }) => self.call("onStats", "(JJJJ)V", |_| {
                Some(vec![
                    JValueOwned::Long(rtt_ms as jlong),
                    JValueOwned::Long(cwnd as jlong),
                    JValueOwned::Long(lost_packets as jlong),
                    JValueOwned::Long(congestion_events as jlong),
                ])
            }),
            // 0 = ended cleanly (we or the peer); otherwise the error code number.
            Event::Closed(code) => self.call("onClosed", "(I)V", |_| Some(vec![JValueOwned::Int(code.map_or(0, ErrorCode::as_i32))])),
        }
    }
}

fn read_string(env: &mut JNIEnv, value: &JString) -> Option<String> {
    env.get_string(value).ok().map(String::from)
}

/// JNI: `QuicCore.nativeConnect(host, port, fpHex, tokB64, events): Long`.
#[no_mangle]
pub extern "system" fn Java_expo_modules_selfadb_quic_QuicCore_nativeConnect(
    mut env: JNIEnv,
    _class: JClass,
    host: JString,
    port: jint,
    fp_hex: JString,
    tok_b64: JString,
    events: JObject,
) -> jlong {
    let outcome = catch_unwind(AssertUnwindSafe(|| -> Result<jlong, ConnectFailure> {
        let (Some(host), Some(fp), Some(tok)) = (read_string(&mut env, &host), read_string(&mut env, &fp_hex), read_string(&mut env, &tok_b64)) else {
            return Err(ConnectFailure::Internal);
        };
        let port = u16::try_from(port).map_err(|_| ConnectFailure::Port)?;
        let params = ConnectParams::parse(&host, port, &fp, &tok).map_err(ConnectFailure::from)?;
        let vm = env.get_java_vm().map_err(|_| ConnectFailure::Internal)?;
        let _ = VM.set(env.get_java_vm().map_err(|_| ConnectFailure::Internal)?);
        let events = env.new_global_ref(&events).map_err(|_| ConnectFailure::Internal)?;
        let client = Client::connect(params, Arc::new(JniSink { vm, events }), Timeouts::default());
        Ok(CLIENTS.insert(client))
    }));
    match outcome {
        Ok(Ok(handle)) => handle,
        Ok(Err(failure)) => failure as i64,
        Err(_) => ConnectFailure::Internal as i64,
    }
}

fn with_client<R>(handle: jlong, default: R, f: impl FnOnce(&Client) -> R) -> R {
    match catch_unwind(AssertUnwindSafe(|| CLIENTS.get(handle).map(|client| f(&client)))) {
        Ok(Some(value)) => value,
        _ => default,
    }
}

fn flag(ok: bool) -> jboolean {
    if ok {
        JNI_TRUE
    } else {
        JNI_FALSE
    }
}

/// JNI: `QuicCore.nativeSessionWrite(handle, line): Boolean`.
#[no_mangle]
pub extern "system" fn Java_expo_modules_selfadb_quic_QuicCore_nativeSessionWrite(
    mut env: JNIEnv,
    _class: JClass,
    handle: jlong,
    line: JString,
) -> jboolean {
    let Some(line) = read_string(&mut env, &line) else { return JNI_FALSE };
    flag(with_client(handle, false, |client| client.session_write(&line)))
}

/// JNI: `QuicCore.nativeSendDatagram(handle, bytes): Boolean`.
#[no_mangle]
pub extern "system" fn Java_expo_modules_selfadb_quic_QuicCore_nativeSendDatagram(
    env: JNIEnv,
    _class: JClass,
    handle: jlong,
    bytes: JByteArray,
) -> jboolean {
    let Ok(data) = env.convert_byte_array(&bytes) else { return JNI_FALSE };
    flag(with_client(handle, false, |client| client.send_datagram(&data)))
}

/// JNI: `QuicCore.nativeOpenUni(handle, channel): Long`: a stream id > 0, or the negative of an `ErrorCode` number.
#[no_mangle]
pub extern "system" fn Java_expo_modules_selfadb_quic_QuicCore_nativeOpenUni(_env: JNIEnv, _class: JClass, handle: jlong, channel: jint) -> jlong {
    let Some(channel) = QuicChannel::from_type_id(channel as u64) else { return -i64::from(ErrorCode::Protocol.as_i32()) };
    with_client(handle, -i64::from(ErrorCode::LinkLost.as_i32()), |client| match client.open_uni(channel) {
        Ok(id) => id as i64,
        Err(code) => -i64::from(code.as_i32()),
    })
}

/// JNI: `QuicCore.nativeStreamWrite(handle, id, bytes): Boolean`.
#[no_mangle]
pub extern "system" fn Java_expo_modules_selfadb_quic_QuicCore_nativeStreamWrite(
    env: JNIEnv,
    _class: JClass,
    handle: jlong,
    id: jlong,
    bytes: JByteArray,
) -> jboolean {
    let Ok(data) = env.convert_byte_array(&bytes) else { return JNI_FALSE };
    flag(with_client(handle, false, |client| client.stream_write(id as u64, &data)))
}

/// JNI: `QuicCore.nativeStreamFinish(handle, id): Boolean`.
#[no_mangle]
pub extern "system" fn Java_expo_modules_selfadb_quic_QuicCore_nativeStreamFinish(_env: JNIEnv, _class: JClass, handle: jlong, id: jlong) -> jboolean {
    flag(with_client(handle, false, |client| client.stream_finish(id as u64)))
}

/// JNI: `QuicCore.nativeClose(handle, code)`: closes, waits for the CONNECTION_CLOSE to leave (at most a few seconds) and forgets the handle.
#[no_mangle]
pub extern "system" fn Java_expo_modules_selfadb_quic_QuicCore_nativeClose(_env: JNIEnv, _class: JClass, handle: jlong, code: jint) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if let Some(client) = CLIENTS.remove(handle) {
            client.close(u32::try_from(code).unwrap_or(0));
        }
    }));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn handles_are_positive_unique_and_forgotten_when_removed() {
        let registry: Registry<&str> = Registry::new();
        let a = registry.insert("a");
        let b = registry.insert("b");
        assert!(a > 0 && b > 0 && a != b);
        assert_eq!(registry.get(a).as_deref(), Some(&"a"));
        assert_eq!(registry.len(), 2);
        assert_eq!(registry.remove(a).as_deref(), Some(&"a"));
        assert!(registry.get(a).is_none(), "a closed handle must be a miss, not a crash");
        assert!(registry.remove(a).is_none(), "closing twice is harmless");
        assert_eq!(registry.get(b).as_deref(), Some(&"b"));
        assert!(registry.get(0).is_none() && registry.get(-1).is_none() && registry.get(i64::MAX).is_none());
    }

    #[test]
    fn a_handle_is_never_reused() {
        let registry: Registry<u8> = Registry::new();
        let first = registry.insert(1);
        registry.remove(first);
        assert_ne!(registry.insert(2), first);
    }

    #[test]
    fn connect_failures_have_fixed_negative_numbers() {
        // Kotlin's QuicCore maps these numbers: they may not drift.
        assert_eq!(ConnectFailure::Host as i64, -1);
        assert_eq!(ConnectFailure::Port as i64, -2);
        assert_eq!(ConnectFailure::Fingerprint as i64, -3);
        assert_eq!(ConnectFailure::Token as i64, -4);
        assert_eq!(ConnectFailure::Internal as i64, -5);
        assert_eq!(ConnectFailure::from(ParamError::Fingerprint), ConnectFailure::Fingerprint);
        assert_eq!(ConnectFailure::from(ParamError::Token), ConnectFailure::Token);
    }
}
