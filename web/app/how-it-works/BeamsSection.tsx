"use client";

import { useEffect, useState, type ReactNode } from "react";
import { useReducedMotion } from "motion/react";
import {
  BluetoothIcon,
  CheckIcon,
  LaptopIcon,
  LockIcon,
  ServerIcon,
  SmartphoneIcon,
} from "@/components/icons";
import { generateRandomChar } from "@/lib/utils";

const CLIP_TEXT = "Meeting at 4";

/* Station centers in a gapless 3-col grid */
const AT_PHONE = "16.67%";
const AT_RELAY = "50%";
const AT_MAC = "83.33%";

/* One packet round-trip, as a chained state machine — each phase schedules
   the next, so the chip, the scramble and the card pings can never drift
   apart. Fade in at the phone, slide, fade out at the Mac, repeat. */
const PHASES = [
  { name: "send", left: AT_PHONE, dur: 1000 }, // fades in, phone pings
  { name: "toRelay", left: AT_RELAY, dur: 1700 }, // seals mid-flight
  { name: "atRelay", left: AT_RELAY, dur: 1200 }, // relay pings, logs "opaque"
  { name: "toMac", left: AT_MAC, dur: 1700 }, // still sealed
  { name: "open", left: AT_MAC, dur: 1600 }, // unseals, Mac pings
  { name: "fade", left: AT_MAC, dur: 500 }, // fades out
  { name: "jump", left: AT_PHONE, dur: 400 }, // snaps back, hidden
] as const;

type PhaseName = (typeof PHASES)[number]["name"];

/* Scramble the displayed text toward `target`, left to right */
function useScramble(target: string, duration = 700) {
  const [text, setText] = useState(target);

  useEffect(() => {
    let raf: number;
    const start = performance.now();
    const tick = (now: number) => {
      const progress = Math.min((now - start) / duration, 1);
      const settled = Math.floor(progress * target.length);
      setText(
        target
          .split("")
          .map((ch, i) =>
            ch === " " || i < settled ? ch : generateRandomChar(),
          )
          .join(""),
      );
      if (progress < 1) raf = requestAnimationFrame(tick);
    };
    raf = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(raf);
  }, [target, duration]);

  return text;
}

function Endpoint({
  icon,
  active,
  tone = "cyan",
  title,
  detail,
  status,
  statusActive,
}: {
  icon: ReactNode;
  active: boolean;
  tone?: "cyan" | "green";
  title: string;
  detail: string;
  status: string;
  statusActive: boolean;
}) {
  return (
    <div className="flex flex-col items-center">
      <div className="relative z-10 flex size-32 flex-col items-center justify-center gap-3 rounded-3xl border border-line bg-surface-2 text-fg-2 shadow-lg shadow-black/5 sm:size-36 dark:shadow-black/30 [&_svg]:size-10">
        {active && (
          <span
            aria-hidden
            className={`card-ping absolute inset-0 rounded-3xl border-2 motion-reduce:hidden ${
              tone === "green" ? "border-green/50" : "border-cyan/50"
            }`}
          />
        )}
        {icon}
        <span className="text-[13px] font-bold tracking-tight text-fg">
          {title}
        </span>
      </div>
      <p className="mt-4 text-center text-[12.5px] text-fg-3">{detail}</p>
      <p
        className={`mt-1.5 font-mono text-[10.5px] tracking-tight transition-colors duration-300 ${
          statusActive
            ? tone === "green"
              ? "text-green"
              : "text-cyan"
            : "text-fg-3/60"
        }`}
      >
        {status}
      </p>
    </div>
  );
}

/* Vertical dashed connector for the stacked mobile layout */
function MobileLink() {
  return (
    <div
      aria-hidden
      className="my-5 h-8 w-px border-l border-dashed border-badge md:hidden"
    />
  );
}

export default function BeamsSection() {
  const reducedMotion = useReducedMotion();
  const [phaseIndex, setPhaseIndex] = useState(0);
  const [cipher, setCipher] = useState<string | null>(null);

  const phase: PhaseName = PHASES[phaseIndex].name;

  // advance the timeline
  useEffect(() => {
    if (reducedMotion) return;
    const t = setTimeout(
      () => setPhaseIndex((i) => (i + 1) % PHASES.length),
      PHASES[phaseIndex].dur,
    );
    return () => clearTimeout(t);
  }, [phaseIndex, reducedMotion]);

  // seal shortly after leaving the phone; unseal on arrival at the Mac
  useEffect(() => {
    if (phase === "toRelay") {
      const t = setTimeout(() => setCipher(generateRandomChar(12)), 300);
      return () => clearTimeout(t);
    }
    if (phase === "open") setCipher(null);
  }, [phase]);

  const sealed = cipher !== null;
  const display = useScramble(cipher ?? CLIP_TEXT);
  const moving = phase === "toRelay" || phase === "toMac";
  const hidden = phase === "fade" || phase === "jump";

  return (
    <section className="mx-auto max-w-6xl px-5 py-16 sm:px-8">
      <div className="rise-2 rounded-[2rem] bg-surface p-6 sm:p-10">
        {/* The three stations */}
        <div className="flex flex-col items-center md:grid md:grid-cols-3">
          <Endpoint
            icon={<SmartphoneIcon />}
            active={phase === "send"}
            tone="green"
            title="Android"
            detail="background service"
            status="clip copied · sealing"
            statusActive={phase === "send" || phase === "toRelay"}
          />
          <MobileLink />
          <Endpoint
            icon={<ServerIcon />}
            active={phase === "atRelay"}
            title="Your relay"
            detail="a deliberately dumb pipe"
            status="⇄ fwd 96 B · opaque"
            statusActive={phase === "atRelay"}
          />
          <MobileLink />
          <Endpoint
            icon={<LaptopIcon />}
            active={phase === "open"}
            tone="green"
            title="Mac"
            detail="menu-bar agent"
            status="✓ opened · pasted"
            statusActive={phase === "open"}
          />
        </div>

        {/* The animation line — the frame fades in at the phone, slides
            across, and fades out at the Mac */}
        <div aria-hidden className="relative mt-8 hidden h-12 md:block">
          <div className="absolute inset-x-[16.67%] top-1/2 h-px bg-gradient-to-r from-badge/40 via-badge to-badge/40" />
          {[AT_PHONE, AT_RELAY, AT_MAC].map((x) => (
            <span
              key={x}
              className="absolute top-1/2 size-1.5 -translate-x-1/2 -translate-y-1/2 rounded-full bg-badge"
              style={{ left: x }}
            />
          ))}

          <div
            className="absolute top-1/2 z-10 -translate-x-1/2 -translate-y-1/2 motion-reduce:hidden"
            style={{
              left: PHASES[phaseIndex].left,
              opacity: hidden ? 0 : 1,
              transition: [
                moving
                  ? "left 1.7s cubic-bezier(0.45, 0, 0.55, 1)"
                  : phase === "jump"
                    ? "none"
                    : "left 0.3s",
                phase === "jump" ? "" : "opacity 0.45s",
              ]
                .filter(Boolean)
                .join(", "),
            }}
          >
            <span
              className={`flex items-center gap-1.5 rounded-full border bg-surface-2 px-3 py-1.5 font-mono text-[11px] whitespace-nowrap shadow-lg shadow-black/10 transition-colors duration-300 dark:shadow-black/40 ${
                sealed ? "border-line text-fg-3" : "border-green/40 text-green"
              }`}
            >
              {sealed ? (
                <LockIcon className="size-3 shrink-0 text-cyan" />
              ) : (
                <span className="text-green/60">“</span>
              )}
              <span className="w-[12ch] text-center">{display}</span>
              {phase === "open" && (
                <CheckIcon className="size-3 shrink-0 text-green" />
              )}
            </span>
          </div>
        </div>

        {/* Bluetooth presence beacon — phone ↔ Mac directly, skips the relay */}
        <div
          aria-hidden
          className="relative mx-[16.67%] mt-4 hidden h-20 md:block"
        >
          <svg
            className="absolute inset-0 h-full w-full overflow-visible"
            viewBox="0 0 600 80"
            preserveAspectRatio="none"
            fill="none"
          >
            <path
              d="M 4 6 C 140 80, 460 80, 596 6"
              stroke="var(--blue)"
              strokeOpacity="0.55"
              strokeWidth="1.5"
              strokeDasharray="5 6"
              strokeLinecap="round"
              vectorEffect="non-scaling-stroke"
              className="ble-dash"
            />
          </svg>
          <span className="ble-ping absolute top-[6px] left-[2px] size-1.5 -translate-x-1/2 -translate-y-1/2 rounded-full bg-blue" />
          <span className="absolute top-[6px] right-[2px] size-1.5 translate-x-1/2 -translate-y-1/2 rounded-full bg-blue/70" />
        </div>
        <div className="mt-2 hidden justify-center md:flex">
          <p className="flex items-center gap-2 rounded-full border border-dashed border-badge px-4 py-2 text-[12px] font-medium text-fg-2">
            <BluetoothIcon className="size-3.5 text-blue" />
            presence beacon — phone ↔ Mac directly, fully local, no internet
          </p>
        </div>

        {/* Mobile fallback for the beacon note */}
        <div className="mt-8 flex flex-col items-center gap-1.5 rounded-(--radius-card) border border-dashed border-badge px-5 py-4 text-center md:hidden">
          <p className="flex items-center gap-2 text-[13px] font-semibold text-fg-2">
            <BluetoothIcon className="size-4 text-blue" />
            Bluetooth presence beacon
          </p>
          <p className="text-[12px] text-fg-3">
            phone ↔ Mac directly — powers proximity auto-lock, fully local
          </p>
        </div>

        <p className="mt-8 text-center font-mono text-[11px] tracking-wide text-fg-3">
          frames: clip · cmd · stat · note · sms — all sealed with
          ChaCha20-Poly1305
        </p>
      </div>
    </section>
  );
}
