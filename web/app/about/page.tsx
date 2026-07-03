import type { Metadata } from "next";
import {
  ArrowRightIcon,
  CastIcon,
  CheckIcon,
  FolderIcon,
  GithubIcon,
  MessageIcon,
  ShieldIcon,
} from "@/components/icons";
import { Reveal } from "@/components/reveal";
import { ButtonLink, Chip, IconBadge, SectionHeading } from "@/components/ui";
import { GITHUB_URL } from "@/lib/links";

export const metadata: Metadata = {
  title: "About",
  description:
    "Why Link to Mac exists: a personal, self-hosted alternative to Link to Windows — what it does today, and what's on the roadmap.",
};

const TODAY = [
  "Two-way clipboard sync (text)",
  "Remote lock from the phone",
  "Proximity auto-lock over Bluetooth",
  "Live battery telemetry, both directions",
  "Notification mirroring to native Mac banners",
  "SMS threads on the Mac (read-only)",
  "LAN-direct with automatic relay fallback",
  "End-to-end encryption with replay protection",
];

const ROADMAP = [
  {
    icon: <FolderIcon />,
    title: "File transfer",
    text: "Send files between phone and Mac — the “Received files” card is already waiting on the Home screen.",
  },
  {
    icon: <MessageIcon />,
    title: "Reply to messages",
    text: "Answer SMS from the Mac's Messages tab instead of just reading them.",
  },
  {
    icon: <CastIcon />,
    title: "Screen casting",
    text: "Mirror the phone's screen into the dashboard, plus the Calls and Photos tabs beside it.",
  },
];

export default function About() {
  return (
    <>
      <section className="mx-auto max-w-6xl px-5 pt-20 pb-6 sm:px-8">
        <div className="rise-1">
          <SectionHeading
            eyebrow="About"
            title="Built because it didn't exist"
            lead="Microsoft ships “Link to Windows®”. Apple® links iPhone® to Mac®. An Android phone next to a Mac gets nothing — this project fills that gap, without handing your clipboard to a cloud."
          />
        </div>
      </section>

      <section className="mx-auto max-w-3xl px-5 py-10 sm:px-8">
        <div className="rise-2 space-y-5 text-[15.5px] leading-relaxed text-fg-2">
          <p>
            Link to Mac is a personal-use, open-source project by{" "}
            <a
              href="https://github.com/grkndev"
              target="_blank"
              rel="noopener noreferrer"
              className="font-semibold text-fg underline decoration-fg-3 underline-offset-4 transition-colors hover:decoration-fg"
            >
              grkndev
            </a>
            . It isn't on the Play Store or the App Store, and that's the
            point: you build or sideload it, you host the relay (or skip it),
            and nothing about your phone or your Mac touches anyone else's
            infrastructure.
          </p>
          <p>
            The design bar is simple — it should feel like a feature the two
            operating systems forgot to ship. A Material 3 app on the phone, a
            native menu-bar agent on the Mac, and a link that quietly picks the
            best path between them.
          </p>
        </div>
        <div className="mt-8 flex flex-wrap gap-2">
          <Chip icon={<ShieldIcon className="size-3.5" />}>
            No cloud, no account, no telemetry
          </Chip>
          <Chip>One phone, one Mac</Chip>
          <Chip>Personal-use project</Chip>
        </div>
      </section>

      {/* What it does today */}
      <section className="border-y border-line bg-surface">
        <div className="mx-auto max-w-3xl px-5 py-14 sm:px-8">
          <h2 className="text-2xl font-bold tracking-tight">
            What it does today
          </h2>
          <ul className="mt-6 grid gap-3 sm:grid-cols-2">
            {TODAY.map((item) => (
              <li
                key={item}
                className="flex items-start gap-3 text-[14.5px] leading-relaxed text-fg-2"
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

      {/* Roadmap */}
      <section className="mx-auto max-w-6xl px-5 py-16 sm:px-8">
        <SectionHeading
          eyebrow="Roadmap"
          title="What's next"
          lead="The Home screen already hints at it — some cards are just waiting for their feature."
        />
        <div className="mt-12 grid gap-4 md:grid-cols-3">
          {ROADMAP.map(({ icon, title, text }, i) => (
            <Reveal
              key={title}
              delay={i * 80}
              className="group rounded-(--radius-card-lg) bg-surface-2 p-7 transition-all duration-300 hover:-translate-y-1 hover:shadow-xl hover:shadow-black/10 dark:hover:shadow-black/25"
            >
              <IconBadge>{icon}</IconBadge>
              <h3 className="mt-5 text-[17px] font-bold tracking-tight">
                {title}
              </h3>
              <p className="mt-2 text-[14.5px] leading-relaxed text-fg-2">
                {text}
              </p>
            </Reveal>
          ))}
        </div>
        <div className="mt-12 flex flex-col items-center justify-center gap-3 sm:flex-row">
          <ButtonLink href={GITHUB_URL} glow>
            <GithubIcon className="size-4.5" />
            Follow along on GitHub
          </ButtonLink>
          <ButtonLink href="/get-started" variant="tonal">
            Try it yourself
            <ArrowRightIcon className="size-4.5 transition-transform duration-200 group-hover:translate-x-1" />
          </ButtonLink>
        </div>
      </section>
    </>
  );
}
