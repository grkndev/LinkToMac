"use client";

import Image from "next/image";
import { useRef } from "react";
import { AnimatedBeam } from "@/components/ui/animated-beam";

/* The hero's device pair — real app screenshots linked by two animated beams
   (one per direction). */
export function HeroDevices() {
  const containerRef = useRef<HTMLDivElement>(null);
  const macAnchor = useRef<HTMLDivElement>(null);
  const phoneAnchor = useRef<HTMLDivElement>(null);

  return (
    <div
      ref={containerRef}
      className="rise-4 relative mt-16 flex flex-col items-center justify-center gap-10 lg:mt-20 lg:flex-row lg:items-end lg:gap-0"
    >
      {/* Beams first in the DOM so the devices paint on top of them */}
      <div
        aria-hidden
        className="pointer-events-none absolute inset-0 hidden lg:block"
      >
        <div className="motion-reduce:hidden">
          <AnimatedBeam
            containerRef={containerRef}
            fromRef={macAnchor}
            toRef={phoneAnchor}
            curvature={90}
            pathColor="rgba(255, 255, 255, 0.6)"
            pathOpacity={0.16}
            pathWidth={2}
            gradientStartColor="#60a5fa"
            gradientStopColor="#22d3ee"
            duration={4.5}
          />
          <AnimatedBeam
            containerRef={containerRef}
            fromRef={macAnchor}
            toRef={phoneAnchor}
            reverse
            curvature={130}
            pathColor="rgba(255, 255, 255, 0.6)"
            pathOpacity={0.1}
            pathWidth={2}
            gradientStartColor="#4ade80"
            gradientStopColor="#22d3ee"
            duration={5.5}
            delay={1.4}
          />
        </div>
      </div>

      {/* Mac dashboard window (screenshot ships its own corners + shadow) */}
      <div className="relative w-full max-w-[660px] lg:translate-x-4">
        <div
          ref={macAnchor}
          aria-hidden
          className="absolute top-2 left-1/3 size-px"
        />
        <Image
          src="/macOS_Windowed.png"
          alt="The Mac dashboard window: the paired phone connected over LAN at 45% battery, with Lock Phone, Cast Screen, Clipboard and Settings quick actions and the Notifications tab"
          width={649}
          height={389}
          priority
          className="w-full"
        />
        {/* Menu-bar popover, floating for depth */}
        <Image
          src="/macOS_MenuBar.png"
          alt="The macOS menu-bar popover: the phone shown as connected over LAN at 45% battery"
          width={619}
          height={260}
          priority
          className="float-y absolute -bottom-8 -left-3 w-[280px] max-w-[46%] rounded-xl border border-line shadow-2xl shadow-black/60 sm:-left-6"
        />
      </div>

      {/* Android app, framed in a phone bezel */}
      <div className="relative shrink-0 lg:-translate-x-10 lg:translate-y-10">
        <div
          ref={phoneAnchor}
          aria-hidden
          className="absolute top-36 left-0 size-px"
        />
        <div className="w-[270px] rounded-[44px] border border-line bg-black p-2.5 shadow-2xl shadow-black/60">
          <Image
            src="/Mobile_Index.jpg"
            alt="The Android app's home screen: the paired MacBook Air connected over LAN at 94% battery, with Lock Mac, Cast Screen, Received files and Clipboard controls"
            width={1440}
            height={3120}
            priority
            className="w-full rounded-[34px]"
          />
        </div>
      </div>
    </div>
  );
}
