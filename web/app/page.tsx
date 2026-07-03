import Link from "next/link";
import {
  ArrowRightIcon,
  BatteryIcon,
  BellIcon,
  BluetoothIcon,
  ClipboardIcon,
  CloudIcon,
  DownloadIcon,
  GithubIcon,
  LockIcon,
  MessageIcon,
  QrCodeIcon,
  ShieldIcon,
  WifiIcon,
} from "@/components/icons";
import { HeroDevices } from "@/components/hero-devices";
import { Reveal } from "@/components/reveal";
import { ButtonLink, Chip, IconBadge, SectionHeading } from "@/components/ui";
import { BorderBeam } from "@/components/ui/border-beam";
import { MagicCard } from "@/components/ui/magic-card";
import { GITHUB_URL, RELEASES_URL } from "@/lib/links";
import { Highlighter } from "@/components/ui/highlighter";

const FEATURES = [
  {
    icon: <ClipboardIcon />,
    title: "Two-way clipboard",
    text: "Copy on the phone, paste on the Mac — and the other way around. It keeps working even after the app is swiped away.",
  },
  {
    icon: <LockIcon />,
    title: "Lock from your phone",
    text: "One tap on the Home screen locks your Mac, wherever you are.",
  },
  {
    icon: <BluetoothIcon />,
    title: "Auto-lock when you leave",
    text: "The Mac watches your phone's Bluetooth beacon and locks itself when the signal fades. No internet needed.",
  },
  {
    icon: <BatteryIcon />,
    title: "Battery, both ways",
    text: "Your Mac's charge lives on the phone's Home screen; your phone's battery and name show on the Mac's dashboard, live.",
  },
  {
    icon: <BellIcon />,
    title: "Notification mirroring",
    text: "Android notifications pop up as native Mac banners and collect in the dashboard — one-way, pausable any time.",
  },
  {
    icon: <MessageIcon />,
    title: "Read your messages",
    text: "SMS threads appear in the Mac's Messages tab so you can read texts without unlocking your phone.",
  },
];

const TRANSPORTS = [
  {
    icon: <WifiIcon />,
    title: "At home: LAN-direct",
    text: "On the same Wi-Fi the phone connects straight to the Mac — it finds it automatically. No relay, no round trip, no setup.",
  },
  {
    icon: <CloudIcon />,
    title: "Away: your own relay",
    text: "Leave home and it falls back to a tiny WebSocket server you host — routed only by a shared room id. Docker-ready.",
  },
  {
    icon: <BluetoothIcon />,
    title: "Offline: Bluetooth",
    text: "Proximity auto-lock uses neither. The phone broadcasts a presence beacon; the Mac locks when it fades — fully local.",
  },
];

export default function Home() {
  return (
    <>
      {/* ───────────────────────── Hero ───────────────────────── */}
      <section className="relative overflow-hidden">
        <div
          aria-hidden
          className="pointer-events-none absolute inset-x-0 top-0 h-[540px] bg-[radial-gradient(55%_60%_at_42%_0%,rgba(59,130,246,0.16),transparent),radial-gradient(45%_55%_at_65%_8%,rgba(34,211,238,0.09),transparent)]"
        />
        <div className="relative mx-auto max-w-6xl px-5 pt-20 pb-16 sm:px-8 sm:pt-28">
          <div className="mx-auto max-w-3xl text-center">
            <div className="rise-1 flex flex-wrap justify-center gap-2">
              <Chip icon={<ShieldIcon className="size-3.5 text-cyan" />}>
                End-to-end encrypted
              </Chip>
              <Chip icon={<CloudIcon className="size-3.5" />}>Self-hosted</Chip>
              <Chip tone="green">Open source</Chip>
            </div>
            <h1 className="rise-2 mt-7 text-5xl font-extrabold tracking-tight text-balance sm:text-6xl md:text-7xl">
              Your phone and your Mac,{" "}
              <Highlighter action="underline" color="#FF9800" multiline strokeWidth={4}>
                finally linked
              </Highlighter>
              .
            </h1>
            <p className="rise-3 mx-auto mt-6 max-w-xl text-lg leading-relaxed text-fg-2 text-pretty">
              Sync your clipboard both ways, lock your Mac from your phone, and
              let it lock itself when you walk away — over your Wi-Fi, or
              through a relay you host yourself. Like “Link to Windows”, but
              yours.
            </p>
            <div className="rise-4 mt-9 flex flex-col items-center justify-center gap-3 sm:flex-row">
              <ButtonLink href={RELEASES_URL} glow>
                <DownloadIcon className="size-4.5 transition-transform duration-200 group-hover:translate-y-0.5" />
                Download latest
              </ButtonLink>
              <ButtonLink href={GITHUB_URL} variant="tonal">
                <GithubIcon className="size-4.5" />
                View on GitHub
              </ButtonLink>
            </div>
            <p className="rise-4 mt-5 text-[13px] text-fg-3">
              macOS menu-bar app + Android app · pair once with a QR code
            </p>
          </div>

          {/* Device mockups, linked by animated beams */}
          <HeroDevices />
        </div>
      </section>

      {/* ─────────────────────── Features ─────────────────────── */}
      <section className="mx-auto max-w-6xl px-5 py-20 sm:px-8 sm:py-28">
        <Reveal>
          <SectionHeading
            eyebrow="Features"
            title="Everything a link should do"
            lead="Six things, done quietly in the background — on the Home screen of your phone and in the menu bar of your Mac."
          />
        </Reveal>
        <ul className="mt-14 grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
          {FEATURES.map(({ icon, title, text }, i) => (
            <Reveal as="li" key={title} delay={(i % 3) * 80}>
              <MagicCard
                gradientFrom="var(--blue)"
                gradientTo="var(--cyan)"
                gradientColor="var(--surface-3)"
                gradientOpacity={0.55}
                className="h-full rounded-(--radius-card-lg) [--color-background:var(--surface-2)] [--color-border:var(--line)] transition-[translate,box-shadow] duration-300 hover:-translate-y-1 hover:shadow-xl hover:shadow-black/10 dark:hover:shadow-black/25"
              >
                <div className="p-7">
                  <IconBadge>{icon}</IconBadge>
                  <h3 className="mt-5 text-[17px] font-bold tracking-tight">
                    {title}
                  </h3>
                  <p className="mt-2 text-[14.5px] leading-relaxed text-fg-2">
                    {text}
                  </p>
                </div>
              </MagicCard>
            </Reveal>
          ))}
        </ul>
      </section>

      {/* ─────────────────── Transports band ─────────────────── */}
      <section className="border-y border-line bg-surface">
        <div className="mx-auto max-w-6xl px-5 py-20 sm:px-8 sm:py-28">
          <Reveal>
            <SectionHeading
              eyebrow="No third party"
              title="Three ways to stay connected"
              lead="The link picks the best path on its own and falls back automatically. None of them belong to anyone but you."
            />
          </Reveal>
          <div className="mt-14 grid gap-4 md:grid-cols-3">
            {TRANSPORTS.map(({ icon, title, text }, i) => (
              <Reveal key={title} delay={i * 80}>
                <MagicCard
                  gradientFrom="var(--blue)"
                  gradientTo="var(--cyan)"
                  gradientColor="var(--surface-3)"
                  gradientOpacity={0.55}
                  className="h-full rounded-(--radius-card-lg) [--color-background:var(--surface-2)] [--color-border:var(--line)] transition-[translate,box-shadow] duration-300 hover:-translate-y-1 hover:shadow-xl hover:shadow-black/10 dark:hover:shadow-black/25"
                >
                  <div className="p-7">
                    <IconBadge tone="raised">{icon}</IconBadge>
                    <h3 className="mt-5 text-[17px] font-bold tracking-tight">
                      {title}
                    </h3>
                    <p className="mt-2 text-[14.5px] leading-relaxed text-fg-2">
                      {text}
                    </p>
                  </div>
                </MagicCard>
              </Reveal>
            ))}
          </div>
          <div className="mt-8 text-center">
            <Link
              href="/how-it-works"
              className="group inline-flex items-center gap-2 rounded-full px-4 py-2 text-[14px] font-semibold text-fg-2 transition-colors hover:bg-surface-2 hover:text-fg"
            >
              See how it works
              <ArrowRightIcon className="size-4 transition-transform duration-200 group-hover:translate-x-1" />
            </Link>
          </div>
        </div>
      </section>

      {/* ─────────────────────── Security ─────────────────────── */}
      <section className="mx-auto max-w-6xl px-5 py-20 sm:px-8 sm:py-28">
        <div className="grid items-center gap-12 lg:grid-cols-2">
          <Reveal>
            <p className="text-link-gradient text-[13px] font-semibold tracking-[0.14em] uppercase">
              Private by construction
            </p>
            <h2 className="mt-3 text-3xl font-bold tracking-tight text-balance sm:text-4xl">
              The relay can’t read a thing
            </h2>
            <p className="mt-4 text-[17px] leading-relaxed text-fg-2">
              Every clip, command and mirrored message is sealed with
              ChaCha20-Poly1305 before it leaves the device, keyed by a secret
              only your phone and your Mac share. The relay just moves opaque
              bytes between two sockets in a room.
            </p>
            <ul className="mt-8 space-y-5">
              {[
                {
                  icon: <ShieldIcon />,
                  title: "End-to-end encryption with replay protection",
                  text: "Authenticated encryption plus a freshness window, so captured frames can't be replayed at you later.",
                },
                {
                  icon: <QrCodeIcon />,
                  title: "Pair once, with a QR code",
                  text: "The Mac shows a QR carrying the pairing secret and connection details. Scan it once and both ends configure themselves.",
                },
                {
                  icon: <CloudIcon />,
                  title: "Your server, your rules",
                  text: "The relay is a tiny Node.js WebSocket server with an auth token and rate limiting. Run it with Docker in a minute — or skip it entirely on your Wi-Fi.",
                },
              ].map(({ icon, title, text }) => (
                <li key={title} className="flex gap-4">
                  <IconBadge size="sm">{icon}</IconBadge>
                  <div>
                    <h3 className="text-[15px] font-bold tracking-tight">
                      {title}
                    </h3>
                    <p className="mt-1 text-[14px] leading-relaxed text-fg-2">
                      {text}
                    </p>
                  </div>
                </li>
              ))}
            </ul>
          </Reveal>

          {/* Encrypted-frame visual */}
          <Reveal
            delay={120}
            className="relative overflow-hidden rounded-(--radius-card-lg) border border-line bg-surface-2 p-7 font-mono text-[13px] leading-7"
          >
            <BorderBeam
              colorFrom="#60a5fa"
              colorTo="#22d3ee"
              size={90}
              duration={9}
              className="motion-reduce:hidden"
            />
            <p className="text-fg-3">{"// what your Mac sends"}</p>
            <p className="mt-1 text-fg">
              {"{"} type: <span className="text-green">&quot;clip&quot;</span>,
              text: <span className="text-green">&quot;Meeting at 4&quot;</span>{" "}
              {"}"}
            </p>
            <p className="mt-6 text-fg-3">{"// what the relay sees"}</p>
            <p className="shimmer mt-1 break-all">
              9f3bax72c41e0d88f2a7b3915c6d4e2f8a1b7c3d5e9f0a2b4c6d8e1f3a5b7c9d0e2f4a6b8c1d3e5f7a9b0c2d4e6f8a
            </p>
            <p className="mt-6 flex items-center gap-2 font-sans text-[13px] font-semibold text-green">
              <ShieldIcon className="size-4" />
              ChaCha20-Poly1305 · keys never leave your devices
            </p>
          </Reveal>
        </div>
      </section>

      {/* ───────────────────── Final CTA ───────────────────── */}
      <section className="mx-auto max-w-6xl px-5 pb-24 sm:px-8">
        <Reveal className="relative overflow-hidden rounded-[2rem] border border-line bg-surface-2 bg-[radial-gradient(70%_100%_at_50%_0%,rgba(59,130,246,0.09),transparent)] px-7 py-16 text-center sm:px-12">
          <BorderBeam
            colorFrom="#60a5fa"
            colorTo="#22d3ee"
            size={110}
            duration={12}
            className="motion-reduce:hidden"
          />
          <h2 className="text-3xl font-bold tracking-tight text-balance sm:text-4xl">
            Link them tonight
          </h2>
          <p className="mx-auto mt-4 max-w-md text-[16px] leading-relaxed text-fg-2">
            A menu-bar app on the Mac, an app on the phone, one QR code between
            them. The relay is optional.
          </p>
          <div className="mt-8 flex flex-col items-center justify-center gap-3 sm:flex-row">
            <ButtonLink href={RELEASES_URL} glow>
              <DownloadIcon className="size-4.5 transition-transform duration-200 group-hover:translate-y-0.5" />
              Download latest
            </ButtonLink>
            <ButtonLink href="/get-started" variant="tonal">
              Read the setup guide
              <ArrowRightIcon className="size-4.5 transition-transform duration-200 group-hover:translate-x-1" />
            </ButtonLink>
          </div>
        </Reveal>
      </section>
    </>
  );
}
