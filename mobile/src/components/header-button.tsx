import { Pressable, Text } from "react-native";

/** Text action for a native navigation header (e.g. the Clipboard screen's "Clear"). */
export function HeaderTextButton({
  label,
  color,
  onPress,
}: {
  label: string;
  color: string;
  onPress: () => void;
}) {
  return (
    <Pressable hitSlop={8} onPress={onPress}>
      <Text style={{ color, fontSize: 16, fontWeight: "600" }}>{label}</Text>
    </Pressable>
  );
}
