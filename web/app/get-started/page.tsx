import type { Metadata } from "next";
import {
  CheckIcon,
  CloudIcon,
  DownloadIcon,
  GithubIcon,
  LaptopIcon,
  QrCodeIcon,
  SmartphoneIcon,
} from "@/components/icons";
import { Reveal } from "@/components/reveal";
import { ButtonLink, IconBadge, SectionHeading } from "@/components/ui";
import { GITHUB_URL, RELEASES_URL } from "@/lib/links";

export const metadata: Metadata = {
  title: "Get started",
  description:
    "Set up Link to macOS: install the Mac menu-bar app and the Android app, pair with a QR code, and optionally host the relay for away-from-home sync.",
};

function CodeBlock({ children }: { children: string }) {
  return (
    <pre className="mt-4 overflow-x-auto rounded-2xl bg-bg p-5 font-mono text-[13px] leading-relaxed text-fg-2">
      <code>{children}</code>
    </pre>
  );
}

function Step({
  number,
  icon,
  title,
  optional,
  children,
}: {
  number: number;
  icon: React.ReactNode;
  title: string;
  optional?: boolean;
  children: React.ReactNode;
}) {
  return (
    <Reveal
      as="li"
      className="relative rounded-(--radius-card-lg) bg-surface-2 p-7 sm:p-9"
    >
      <div className="flex items-center gap-4">
        <IconBadge tone="raised">{icon}</IconBadge>
        <div>
          <p className="text-[12px] font-semibold tracking-[0.14em] text-fg-3 uppercase">
            Step {number}
            {optional && " · optional"}
          </p>
          <h2 className="text-xl font-bold tracking-tight">{title}</h2>
        </div>
      </div>
      <div className="mt-5 text-[15px] leading-relaxed text-fg-2">
        {children}
      </div>
    </Reveal>
  );
}

export default function GetStarted() {
  return (
    <>
      <section className="mx-auto max-w-6xl px-5 pt-20 pb-10 sm:px-8">
        <div className="rise-1">
          <SectionHeading
            eyebrow="Get started"
            title="Linked in three steps"
            lead="A Mac app, a phone app, one QR code. The relay is a fourth, optional step for when you leave the house."
          />
        </div>
        <div className="rise-2 mt-8 flex flex-col items-center justify-center gap-3 sm:flex-row">
          <ButtonLink href={RELEASES_URL} glow>
            <DownloadIcon className="size-4.5 transition-transform duration-200 group-hover:translate-y-0.5" />
            Download latest release
          </ButtonLink>
          <ButtonLink href={GITHUB_URL} variant="tonal">
            <GithubIcon className="size-4.5" />
            View on GitHub
          </ButtonLink>
        </div>
      </section>

      <section className="mx-auto max-w-3xl px-5 pb-16 sm:px-8">
        <ol className="rise-3 space-y-5">
          <Step number={1} icon={<LaptopIcon />} title="Install the Mac app">
            <p>
              Grab the DMG from the latest release, drag Link to macOS into
              Applications and launch it — it lives in your menu bar. LAN-direct
              sync is on by default, so on the same Wi-Fi there is nothing to
              configure.
            </p>
            <p className="mt-3">
              Prefer building from source? Clone the repo and open the Xcode
              project:
            </p>
            <CodeBlock>{`git clone https://github.com/grkndev/LinkToMac.git
cd LinkToMac/mac
xcodegen generate && open LinkToMac.xcodeproj`}</CodeBlock>
          </Step>

          <Step number={2} icon={<SmartphoneIcon />} title="Install the Android app">
            <p>
              Sideload the APK from the same release page (it's a personal-use
              project — it isn't on the Play Store). Then enable{" "}
              <strong className="font-semibold text-fg">
                Developer options → Wireless Debugging
              </strong>{" "}
              — the app uses it once to grant itself background clipboard
              access.
            </p>
            <p className="mt-3">Building it yourself instead:</p>
            <CodeBlock>{`cd LinkToMac/mobile
bun install
bun run android   # dev client — Expo Go is not supported`}</CodeBlock>
          </Step>

          <Step number={3} icon={<QrCodeIcon />} title="Pair with the QR code">
            <p>
              Open <strong className="font-semibold text-fg">Show pairing QR</strong>{" "}
              from the Mac's menu-bar icon and scan it with the phone app. The
              code carries everything — the pairing secret, the Mac's LAN port,
              and the relay address if you've set one — so both ends configure
              themselves. Copy something and paste it on the other device;
              you're linked.
            </p>
          </Step>

          <Step
            number={4}
            icon={<CloudIcon />}
            title="Host the relay"
            optional
          >
            <p>
              Only needed to keep syncing when phone and Mac are on{" "}
              <em>different</em> networks. It's a tiny Node.js WebSocket server;
              run it on any box you own:
            </p>
            <CodeBlock>{`cd LinkToMac/server
cp .env.example .env   # set RELAY_AUTH_TOKEN
docker compose up -d   # or: npm install && npm run dev`}</CodeBlock>
            <p className="mt-3">
              Put it behind a reverse proxy with TLS (wss), then add its
              address in the Mac app under{" "}
              <strong className="font-semibold text-fg">
                Server Settings…
              </strong>{" "}
              and re-show the QR — the phone picks it up on the next scan and
              still prefers the direct LAN link whenever you're home.
            </p>
          </Step>
        </ol>
      </section>

      {/* Checklist */}
      <section className="border-t border-line bg-surface">
        <div className="mx-auto max-w-3xl px-5 py-14 sm:px-8">
          <h2 className="text-xl font-bold tracking-tight">
            Before you start
          </h2>
          <ul className="mt-5 space-y-3">
            {[
              "A Mac running macOS (the app sits in the menu bar and starts at login)",
              "An Android phone with Developer options available",
              "Both devices on the same Wi-Fi for pairing",
              "Optional: a server or NAS for the relay, reachable over TLS from outside",
            ].map((item) => (
              <li
                key={item}
                className="flex items-start gap-3 text-[15px] leading-relaxed text-fg-2"
              >
                <span className="mt-0.5 flex size-5.5 shrink-0 items-center justify-center rounded-full bg-green/10 text-green">
                  <CheckIcon className="size-3" />
                </span>
                {item}
              </li>
            ))}
          </ul>
        </div>
      </section>
    </>
  );
}
