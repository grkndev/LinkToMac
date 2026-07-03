"use client";

import { useState, useEffect } from "react";
import {
  BluetoothIcon,
  CheckIcon,
  LaptopIcon,
  LockIcon,
} from "@/components/icons";
import { HyperText } from "@/components/ui/hyper-text";
import { generateRandomChar } from "@/lib/utils";

const CLIP_TEXT = "Meeting at 4";
const CIPHER_TEXT = "9f3cb1sc41ei";

/* ── The three wire endpoints, drawn in CSS so they follow the theme ── */

function PhoneDevice() {
  return (
    <div className="relative z-10 w-44 rounded-[28px] border border-line bg-surface-2 p-2 shadow-xl shadow-black/10 dark:shadow-black/40">
      <div className="rounded-[20px] bg-bg px-3 pt-2.5 pb-3">
        <div className="flex items-center justify-between font-mono text-[9px] text-fg-3">
          <span>12:14</span>
          <span className="flex items-center gap-1">
            <BluetoothIcon className="size-2.5" />
            45%
          </span>
        </div>
        {/* the paired Mac, as the app's Home screen shows it */}
        <div className="mt-2.5 rounded-xl bg-surface-2 px-2 py-2.5 text-center">
          <LaptopIcon className="mx-auto size-4 text-fg-2" />
          <p className="mt-1 text-[10px] font-semibold tracking-tight">
            MacBook Air
          </p>
          <div className="mt-1.5 flex justify-center gap-1 font-mono text-[8px] text-fg-2">
            <span className="rounded bg-surface-3 px-1 py-px">LAN</span>
            <span className="rounded bg-surface-3 px-1 py-px">94%</span>
          </div>
          <p className="mt-1.5 flex items-center justify-center gap-1 text-[8px] font-medium text-green">
            <span className="size-1 rounded-full bg-green" />
            Connected
          </p>
        </div>
        {/* the clip about to travel */}
        <div className="mt-2 rounded-xl bg-surface-2 px-2 py-1.5">
          <p className="font-mono text-[7.5px] tracking-[0.12em] text-fg-3 uppercase">
            clipboard
          </p>
          <p className="phone-clip mt-1 truncate rounded-md bg-surface-3 px-1.5 py-1 text-[9.5px] font-medium">
            {CLIP_TEXT}
          </p>
        </div>
      </div>
    </div>
  );
}

function RelayDevice() {
  return (
    <div className="relative z-10 w-56 overflow-hidden rounded-xl border border-line bg-surface-2 shadow-xl shadow-black/10 dark:shadow-black/40">
      <div className="flex items-center gap-1.5 border-b border-line px-3 py-2">
        <span className="size-2 rounded-full bg-surface-4" />
        <span className="size-2 rounded-full bg-surface-4" />
        <span className="size-2 rounded-full bg-surface-4" />
        <span className="ml-1.5 font-mono text-[10px] text-fg-3">
          relay — wss://:8787
        </span>
      </div>
      <div className="space-y-1.5 px-3.5 py-3 font-mono text-[10.5px] leading-relaxed">
        <p className="text-fg-3">
          <span className="text-green">✓</span> room a3f9 · 2 peers
        </p>
        <p className="relay-flash text-fg-3">⇄ fwd 96 B → mac · opaque</p>
        <p className="text-fg-3">
          ⚿ plaintext seen: <span className="text-fg-2">none</span>
        </p>
      </div>
    </div>
  );
}

function MacDevice() {
  return (
    <div className="relative z-10 w-60 overflow-hidden rounded-xl border border-line bg-surface-2 shadow-xl shadow-black/10 dark:shadow-black/40">
      <div className="flex items-center gap-1.5 border-b border-line px-3 py-2">
        <span className="size-2 rounded-full bg-[#ff5f57]" />
        <span className="size-2 rounded-full bg-[#febc2e]" />
        <span className="size-2 rounded-full bg-[#28c840]" />
        <span className="ml-1.5 text-[10px] font-semibold tracking-tight text-fg-2">
          Link to macOS
        </span>
      </div>
      <div className="px-3 py-2.5">
        <div className="flex items-center justify-between rounded-lg bg-surface-3 px-2 py-1.5">
          <span className="text-[10px] font-semibold tracking-tight">
            Android
          </span>
          <span className="flex items-center gap-1.5 font-mono text-[8px] text-fg-2">
            <span className="rounded bg-surface-4 px-1 py-px">LAN</span>
            45%
            <span className="size-1 rounded-full bg-green" />
          </span>
        </div>
        {/* where the clip lands */}
        <div className="mt-2 rounded-lg bg-surface-3 px-2 py-1.5">
          <p className="font-mono text-[7.5px] tracking-[0.12em] text-fg-3 uppercase">
            clipboard
          </p>
          <p className="mac-paste mt-1 flex items-center justify-between rounded-md bg-surface-4 px-1.5 py-1 text-[9.5px] font-medium">
            {CLIP_TEXT}
            <CheckIcon className="size-2.5 text-green" />
          </p>
        </div>
      </div>
    </div>
  );
}

function Caption({ title, detail }: { title: string; detail: string }) {
  return (
    <p className="mt-4 text-center text-[12.5px] text-fg-3">
      <span className="font-semibold text-fg-2">{title}</span> · {detail}
    </p>
  );
}

function MobileLink() {
  return (
    <div
      aria-hidden
      className="h-8 w-px border-l border-dashed border-badge md:hidden"
    />
  );
}

export default function BeamsSection() {
  const [isCipher, setIsCipher] = useState(false);
  const [cycleCount, setCycleCount] = useState(0);

  useEffect(() => {
    let t1: NodeJS.Timeout;
    let t2: NodeJS.Timeout;

    const startTimeline = () => {
      setIsCipher(false);
      t1 = setTimeout(() => setIsCipher(true), 1050);
      t2 = setTimeout(() => setIsCipher(false), 4200);
    };

    startTimeline();
    const interval = setInterval(startTimeline, 7000);

    const handleVisibilityChange = () => {
      if (!document.hidden) {
        setCycleCount((c) => c + 1);
      }
    };

    document.addEventListener("visibilitychange", handleVisibilityChange);

    return () => {
      clearInterval(interval);
      clearTimeout(t1);
      clearTimeout(t2);
      document.removeEventListener("visibilitychange", handleVisibilityChange);
    };
  }, [cycleCount]);

  return (
    <section className="mx-auto max-w-6xl px-5 py-16 sm:px-8">
      <style>{`
        .custom-pkt {
          position: absolute;
          top: 46%;
          z-index: 0;
          animation: custom-travel 7s infinite ease-in-out;
        }

        @keyframes custom-travel {
          0% { left: 15%; opacity: 0; }
          5% { left: 16.6%; opacity: 1; }
          15% { left: 30.3%; }
          30% { left: 30.3%; }
          45% { left: 50%; }  
          60% { left: 68.6%; }
          75% { left: 68.6%; }
          90% { left: 83.3%; opacity: 1; }
          95% { left: 83.3%; opacity: 0; }
          100% { left: 83.3%; opacity: 0; }
        }
      `}</style>

      <div className="rise-2 rounded-[2rem] bg-surface p-6 sm:p-10">
        <div className="wire-freeze relative">
          <div
            aria-hidden
            className="absolute inset-x-[7%] top-[46%] hidden h-px bg-gradient-to-r from-transparent via-badge to-transparent md:block"
          />

          <div
            key={cycleCount}
            aria-hidden
            className="custom-pkt hidden -translate-x-1/2 -translate-y-1/2 md:flex motion-reduce:hidden"
          >
            <div
              className={`flex items-center gap-1 justify-self-center rounded-full border px-2.5 py-1 text-[10px] font-medium shadow-lg shadow-black/10 dark:shadow-black/40 transition-all duration-500 ${
                isCipher
                  ? "border-line bg-surface-2 text-fg-3"
                  : "border-green/40 bg-surface-2 text-green"
              }`}
            >
              {/* {isCipher && <LockIcon className="size-2.5 text-cyan shrink-0" />} */}

              {/* Sabit genişlik (w-[80px]) ve ortalama (justify-center) eklendi */}
              <HyperText
                key={isCipher ? "cipher" : "plain"}
                as="span"
                duration={800}
                animateOnHover={false}
                className="flex items-center justify-center p-0 text-[10px] font-mono tracking-tight w-[80px] shrink-0"
              >
                {isCipher ? generateRandomChar(12) : CLIP_TEXT}
              </HyperText>
            </div>
          </div>

          <div className="grid items-center justify-items-center gap-0 md:grid-cols-3 md:gap-24 lg:gap-32">
            <div className="flex flex-col items-center">
              <PhoneDevice />
              <Caption title="Android phone" detail="background service" />
            </div>
            <MobileLink />
            <div className="flex flex-col items-center">
              <RelayDevice />
              <Caption title="Your relay" detail="a deliberately dumb pipe" />
            </div>
            <MobileLink />
            <div className="flex flex-col items-center">
              <MacDevice />
              <Caption title="Mac" detail="menu-bar agent" />
            </div>
          </div>
        </div>

        {/* Bluetooth beacon section */}
        <div
          aria-hidden
          className="relative mx-[16%] mt-2 hidden h-24 md:block"
        >
          <svg
            className="absolute inset-0 h-full w-full overflow-visible"
            viewBox="0 0 600 96"
            preserveAspectRatio="none"
            fill="none"
          >
            <path
              d="M 4 8 C 140 96, 460 96, 596 8"
              stroke="var(--blue)"
              strokeOpacity="0.55"
              strokeWidth="1.5"
              strokeDasharray="5 6"
              strokeLinecap="round"
              vectorEffect="non-scaling-stroke"
              className="ble-dash"
            />
          </svg>
          <span className="ble-ping absolute top-[8px] left-[2px] size-1.5 -translate-x-1/2 -translate-y-1/2 rounded-full bg-blue" />
          <span className="absolute top-[8px] right-[2px] size-1.5 translate-x-1/2 -translate-y-1/2 rounded-full bg-blue/70" />
        </div>
        <div className="mt-2 hidden justify-center md:flex">
          <p className="flex items-center gap-2 rounded-full border border-dashed border-badge px-4 py-2 text-[12px] font-medium text-fg-2">
            <BluetoothIcon className="size-3.5 text-blue" />
            presence beacon — phone ↔ Mac directly, fully local, no internet
          </p>
        </div>

        <div className="mt-6 flex flex-col items-center gap-1.5 rounded-(--radius-card) border border-dashed border-badge px-5 py-4 text-center md:hidden">
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
