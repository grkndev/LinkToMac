import { useEffect, useState } from 'react';
import {
  Button,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';

import SelfAdb from '../../modules/selfadb';

/**
 * Step 3 spike driver. Manual flow (no mDNS yet):
 *   1. Phone: Settings > Developer options > Wireless debugging > ON
 *   2. "Pair device with pairing code" -> note IP:PORT + 6-digit code -> Pair below
 *   3. Back on Wireless debugging main screen -> note IP:PORT (different port) -> Connect
 *   4. Deploy & Run -> copy text anywhere on the phone -> watch "Last clip"
 */
export default function Spike() {
  const [pairHostPort, setPairHostPort] = useState('127.0.0.1:0');
  const [pairCode, setPairCode] = useState('');
  const [connHostPort, setConnHostPort] = useState('127.0.0.1:0');
  const [clipPort] = useState(53123);

  const [writeText, setWriteText] = useState('');
  const [lastClip, setLastClip] = useState('—');
  const [logs, setLogs] = useState<string[]>([]);

  const log = (m: string) =>
    setLogs((prev) => [`${new Date().toLocaleTimeString()}  ${m}`, ...prev].slice(0, 200));

  useEffect(() => {
    const subClip = SelfAdb.addListener('onClip', (e) => {
      setLastClip(e.text);
      log(`clip <- "${e.text.slice(0, 60)}"`);
    });
    const subLog = SelfAdb.addListener('onLog', (e) => log(e.message));
    const subStatus = SelfAdb.addListener('onStatus', (e) =>
      log(`status adb=${e.adb} clip=${e.clip}`),
    );
    return () => {
      subClip.remove();
      subLog.remove();
      subStatus.remove();
    };
  }, []);

  const split = (s: string): [string, number] => {
    const [h, p] = s.split(':');
    return [h?.trim() ?? '127.0.0.1', parseInt(p?.trim() ?? '0', 10)];
  };

  const wrap = (fn: () => Promise<unknown>) => async () => {
    try {
      await fn();
    } catch (e: any) {
      log(`ERR ${e?.message ?? e}`);
    }
  };

  return (
    <ScrollView style={styles.root} contentContainerStyle={styles.content}>
      <Text style={styles.h1}>Self-ADB Spike</Text>

      <Text style={styles.label}>1) Pair (host:port + code)</Text>
      <TextInput style={styles.input} value={pairHostPort} onChangeText={setPairHostPort} autoCapitalize="none" />
      <TextInput style={styles.input} value={pairCode} onChangeText={setPairCode} placeholder="6-digit code" keyboardType="number-pad" />
      <Button
        title="Pair"
        onPress={wrap(async () => {
          const [h, p] = split(pairHostPort);
          log(await SelfAdb.pair(h, p, pairCode));
        })}
      />

      <Text style={styles.label}>2) Connect (host:port)</Text>
      <TextInput style={styles.input} value={connHostPort} onChangeText={setConnHostPort} autoCapitalize="none" />
      <Button
        title="Connect"
        onPress={wrap(async () => {
          const [h, p] = split(connHostPort);
          log(await SelfAdb.connect(h, p));
        })}
      />

      <Text style={styles.label}>3) Deploy & Run (clip port {clipPort})</Text>
      <Button title="Deploy & Run" onPress={wrap(async () => log(await SelfAdb.deployAndRun(clipPort)))} />

      <Text style={styles.label}>Last clip</Text>
      <Text style={styles.clip} selectable>{lastClip}</Text>

      <Text style={styles.label}>Write to phone clipboard</Text>
      <TextInput style={styles.input} value={writeText} onChangeText={setWriteText} placeholder="text..." />
      <Button title="Write" onPress={wrap(async () => SelfAdb.writeClipboard(writeText))} />

      <View style={styles.row}>
        <Button title="Stop (detach, daemon kalır)" onPress={wrap(async () => SelfAdb.stop())} />
      </View>
      <View style={styles.row}>
        <Button title="Kill daemon (adb gerekir)" color="#b00" onPress={wrap(async () => log(await SelfAdb.killDaemon()))} />
      </View>

      <Text style={styles.label}>Log</Text>
      {logs.map((l, i) => (
        <Text key={i} style={styles.logLine}>{l}</Text>
      ))}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: '#0b0b0c' },
  content: { padding: 16, paddingBottom: 64, gap: 6 },
  h1: { color: '#fff', fontSize: 22, fontWeight: '700', marginBottom: 8 },
  label: { color: '#9aa', marginTop: 14, fontSize: 13, fontWeight: '600' },
  input: {
    backgroundColor: '#1a1a1d',
    color: '#fff',
    borderRadius: 8,
    paddingHorizontal: 12,
    paddingVertical: 8,
    marginVertical: 4,
  },
  clip: { color: '#7CFC00', fontFamily: 'monospace', paddingVertical: 6 },
  row: { marginTop: 20 },
  logLine: { color: '#888', fontFamily: 'monospace', fontSize: 11 },
});
