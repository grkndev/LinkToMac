import { Text as ComposeText, type TextProps } from "@expo/ui/jetpack-compose";
import { Children, cloneElement, isValidElement, type ReactNode } from "react";

import { resolveFontFamily } from "@/constants/typography";

type Style = TextProps["style"];

/** `style` with the app typeface for its weight filled in (see constants/typography.ts). */
function withFont(style: Style): NonNullable<Style> {
  return { ...style, fontFamily: resolveFontFamily(style) };
}

/**
 * The app-wide Compose `Text`: identical to `@expo/ui`'s, but it picks the Google Sans Flex /
 * JetBrains Mono family from the requested weight (Compose can't pick a weight inside a custom
 * Typeface family — it's chosen by family name). Use this instead of importing `Text` from
 * `@expo/ui/jetpack-compose`.
 *
 * Inline spans: `@expo/ui` only recognises nested `Text` elements of ITS OWN `Text` type, so a span
 * must be the library `Text` (import it aliased: `Text as SpanText`); this wrapper gives such
 * direct children the font too.
 */
export function Text({ style, children, ...rest }: TextProps) {
  return (
    <ComposeText {...rest} style={withFont(style)}>
      {spanChildren(children)}
    </ComposeText>
  );
}

function spanChildren(children: ReactNode): ReactNode {
  return Children.map(children, (child) => {
    if (isValidElement<TextProps>(child) && child.type === ComposeText) {
      return cloneElement(child, {
        style: withFont(child.props.style),
        children: spanChildren(child.props.children),
      });
    }
    return child;
  });
}
