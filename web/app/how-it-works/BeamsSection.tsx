"use client";
import React from "react";
import {
  BluetoothIcon,
  LaptopIcon,
  ServerIcon,
  SmartphoneIcon,
} from "@/components/icons";
import { IconBadge } from "@/components/ui";
import { AnimatedBeam } from "@/components/ui/animated-beam";
import { BorderBeam } from "@/components/ui/border-beam";
import { Card, CardContent } from "@/components/ui/card";

function DiagramNode({
    index,
  icon,
  title,
  lines,
  ref,
}: {
    index: number;
  icon: React.ReactNode;
  title: string;
  lines: string[];
  ref: React.Ref<HTMLDivElement>;
}) {
  return (
    <Card
      className="flex flex-col w-full items-center rounded-(--radius-card)  px-6 py-7 text-center bg-surface-2 z-10 overflow-hidden relative"
      key={title.length}
      ref={ref}
    >
      <CardContent className="flex flex-col items-center gap-1.5 p-0">
        <IconBadge tone="raised">{icon}</IconBadge>
        <p className="mt-4 text-[15px] font-bold tracking-tight text-primary-foreground">
          {title}
        </p>
        <p className="mt-1.5 text-[12.5px] leading-relaxed text-fg-3">
          {lines.join(" · ")}
        </p>
      </CardContent>
      <BorderBeam
        duration={8}
        size={100}
        delay={1/index}
      />
    </Card>
  );
}

export default function BeamsSection() {
  const containerRef = React.useRef<HTMLDivElement>(null);
  const androidNodeRef = React.useRef<HTMLDivElement>(null);
  const relayNodeRef = React.useRef<HTMLDivElement>(null);
  const macNodeRef = React.useRef<HTMLDivElement>(null);
  return (
    <section className="mx-auto max-w-6xl px-5 py-16 sm:px-8">
      <div className="rise-2 rounded-[2rem] bg-surface p-6 sm:p-10 ">
        <div
          className="relative grid items-center justify-center gap-16 md:grid-cols-3 w-full"
          ref={containerRef}
        >
          <DiagramNode
            index={1}
            icon={<SmartphoneIcon />}
            title="Android phone"
            lines={[
              "background app",
              "clipboard · lock · battery",
              "notifications · SMS",
            ]}
            ref={androidNodeRef}
          />

          <DiagramNode
            index={2}
            icon={<ServerIcon />}
            title="Your relay"
            lines={[
              "tiny WS server",
              "room id routing",
              "sees only ciphertext",
            ]}
            ref={relayNodeRef}
          />

          <DiagramNode
            index={3}
            icon={<LaptopIcon />}
            title="Mac"
            lines={["menu-bar agent", "dashboard window", "pairing QR"]}
            ref={macNodeRef}
          />

          <AnimatedBeam
            containerRef={containerRef}
            fromRef={androidNodeRef}
            toRef={relayNodeRef}
          />
          <AnimatedBeam
            containerRef={containerRef}
            fromRef={relayNodeRef}
            toRef={macNodeRef}
          />
        </div>

        <div className="mt-6 flex flex-col items-center gap-1.5 rounded-(--radius-card) border border-dashed border-badge px-6 py-5 text-center">
          <p className="flex items-center gap-2 text-[14px] font-semibold text-fg-2">
            <BluetoothIcon className="size-4" />
            Bluetooth presence beacon
          </p>
          <p className="text-[13px] text-fg-3">
            phone ↔ Mac directly — powers proximity auto-lock, fully local, no
            internet involved
          </p>
        </div>
      </div>
    </section>
  );
}
