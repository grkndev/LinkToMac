import type { Metadata } from "next";
import {
  ArrowRightIcon,
  BluetoothIcon,
  CloudIcon,
  LaptopIcon,
  ServerIcon,
  ShieldIcon,
  SmartphoneIcon,
  TerminalIcon,
  WifiIcon,
  ZapIcon,
} from "@/components/icons";
import { Reveal } from "@/components/reveal";
import { ButtonLink, IconBadge, SectionHeading } from "@/components/ui";
import BeamsSection from "./BeamsSection";

export const metadata: Metadata = {
  title: "How it works",
  description:
    "The architecture behind Link to macOS: LAN-direct and relay transports, the Bluetooth proximity beacon, end-to-end encryption, and the Android background trick.",
};

const COMPONENTS = [
  {
    icon: <SmartphoneIcon />,
    name: "Android app",
    stack: "Expo · React Native · Kotlin",
    text: "Pairing, settings, and a foreground service that does clipboard sync, mirroring and the Bluetooth beacon — it survives the app being swiped away.",
  },
  {
    icon: <LaptopIcon />,
    name: "Mac menu-bar agent",
    stack: "Swift 6 · SwiftUI",
    text: "Lives in the menu bar with a full dashboard window: your phone's status, clip history, notifications and message threads. Shows the pairing QR.",
  },
  {
    icon: <ServerIcon />,
    name: "Relay server",
    stack: "Node.js · WebSocket",
    text: "A deliberately dumb pipe. Two sockets meet in a room and it shovels opaque, encrypted bytes between them. Auth token, rate limiting, Docker-ready.",
  },
  {
    icon: <TerminalIcon />,
    name: "Privileged daemon",
    stack: "Java · dex",
    text: "The clipboard helper the Android app starts through the phone's own ADB. It has the permissions regular apps lack, and keeps running on its own.",
  },
];



export default function HowItWorks() {
 
  return (
    <>
      <section className="mx-auto max-w-6xl px-5 pt-20 pb-4 sm:px-8">
        <div className="rise-1">
          <SectionHeading
            eyebrow="How it works"
            title="A link with no one in the middle"
            lead="Two apps stay connected over whichever path is best — and everything that crosses a wire is sealed before it leaves the device."
          />
        </div>
      </section>

      {/* Architecture diagram */}
      <BeamsSection />
      

      {/* Transport story */}
      <section className="mx-auto max-w-3xl px-5 py-12 sm:px-8">
        <h2 className="text-2xl font-bold tracking-tight sm:text-3xl">
          The path is chosen for you
        </h2>
        <div className="mt-8 space-y-8">
          <div className="flex gap-5">
            <IconBadge size="sm">
              <WifiIcon />
            </IconBadge>
            <div>
              <h3 className="text-[16px] font-bold">
                Same Wi-Fi? Straight to the Mac.
              </h3>
              <p className="mt-1.5 text-[15px] leading-relaxed text-fg-2">
                The Mac runs a small local server and announces itself on the
                network; the phone finds it automatically and connects
                LAN-direct. No relay hop, lower latency, and it works with zero
                server setup.
              </p>
            </div>
          </div>
          <div className="flex gap-5">
            <IconBadge size="sm">
              <CloudIcon />
            </IconBadge>
            <div>
              <h3 className="text-[16px] font-bold">
                Out the door? The relay takes over.
              </h3>
              <p className="mt-1.5 text-[15px] leading-relaxed text-fg-2">
                When the LAN link drops, both ends fall back to the relay you
                host. Each pairing shares a room id; the relay matches the two
                sockets in that room and forwards frames without understanding
                them. When you come home, the link moves back to LAN on its own.
              </p>
            </div>
          </div>
          <div className="flex gap-5">
            <IconBadge size="sm">
              <BluetoothIcon />
            </IconBadge>
            <div>
              <h3 className="text-[16px] font-bold">
                Walking away? Bluetooth notices.
              </h3>
              <p className="mt-1.5 text-[15px] leading-relaxed text-fg-2">
                The phone broadcasts a low-energy presence beacon derived from
                your pairing — the Mac measures its signal and locks the screen
                when you're out of range. It needs neither Wi-Fi nor the relay,
                so it keeps working with no internet at all. (Locking only —
                macOS offers no way to auto-unlock.)
              </p>
            </div>
          </div>
        </div>
      </section>

      {/* Security */}
      <section className="border-y border-line bg-surface">
        <div className="mx-auto max-w-3xl px-5 py-16 sm:px-8">
          <h2 className="flex items-center gap-3 text-2xl font-bold tracking-tight sm:text-3xl">
            <ShieldIcon className="size-7 text-fg-2" />
            Sealed before it leaves
          </h2>
          <p className="mt-4 text-[15px] leading-relaxed text-fg-2">
            Pairing gives both devices a shared 32-byte secret — it rides in the
            QR code and is stored in the Mac's Keychain and the phone's secure
            storage. From then on, every frame (clips, commands, battery,
            notifications, messages) is encrypted with ChaCha20-Poly1305 on the
            sending device and only opened on the receiving one.
          </p>
          <ul className="mt-6 space-y-3 text-[15px] leading-relaxed text-fg-2">
            {[
              "Each frame is bound to its type, so a captured frame can't be replayed as a different kind of message.",
              "Frames carry a timestamp and are accepted only within a short freshness window; repeats are dropped by a replay cache.",
              "The relay authenticates clients with a token and rate-limits rooms — but even a hostile relay only ever sees ciphertext.",
              "No account, no cloud, no telemetry. The only secrets live on your two devices and in your own server's config.",
            ].map((line) => (
              <li key={line} className="flex gap-3">
                <span
                  aria-hidden
                  className="mt-2.5 size-1.5 shrink-0 rounded-full bg-fg-3"
                />
                {line}
              </li>
            ))}
          </ul>
        </div>
      </section>

      {/* The Android trick */}
      <section className="mx-auto max-w-3xl px-5 py-16 sm:px-8">
        <h2 className="flex items-center gap-3 text-2xl font-bold tracking-tight sm:text-3xl">
          <ZapIcon className="size-7 text-amber" />
          The Android trick
        </h2>
        <p className="mt-4 text-[15px] leading-relaxed text-fg-2">
          Modern Android doesn't let ordinary apps read the clipboard in the
          background — that would normally kill two-way sync the moment you
          switch apps. Link to macOS gets around it honestly: the app pairs with
          the phone's <em>own</em> ADB over Wireless Debugging and starts a tiny
          privileged helper on the device itself. That helper has shell-level
          clipboard access and keeps running even after the app is swiped away.
        </p>
        <p className="mt-4 text-[15px] leading-relaxed text-fg-2">
          Everything stays on your phone — it's your device granting your own
          app more of its own power. Turning on Wireless Debugging once per
          setup is the only ceremony.
        </p>
      </section>

      {/* Components */}
      <section className="mx-auto max-w-6xl px-5 pb-20 sm:px-8">
        <SectionHeading
          eyebrow="Under the hood"
          title="Four small programs, one link"
        />
        <div className="mt-12 grid gap-4 sm:grid-cols-2">
          {COMPONENTS.map(({ icon, name, stack, text }, i) => (
            <Reveal
              key={name}
              delay={(i % 2) * 80}
              className="group rounded-(--radius-card-lg) bg-surface-2 p-7 transition-all duration-300 hover:-translate-y-1 hover:shadow-xl hover:shadow-black/25"
            >
              <div className="flex items-center gap-4">
                <IconBadge>{icon}</IconBadge>
                <div>
                  <h3 className="text-[16px] font-bold tracking-tight">
                    {name}
                  </h3>
                  <p className="text-[12.5px] font-medium text-fg-3">{stack}</p>
                </div>
              </div>
              <p className="mt-4 text-[14.5px] leading-relaxed text-fg-2">
                {text}
              </p>
            </Reveal>
          ))}
        </div>
        <div className="mt-12 text-center">
          <ButtonLink href="/get-started" variant="tonal">
            Set it up yourself
            <ArrowRightIcon className="size-4.5 transition-transform duration-200 group-hover:translate-x-1" />
          </ButtonLink>
        </div>
      </section>
    </>
  );
}
