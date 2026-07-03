import Link from "next/link";
import type { ReactNode } from "react";

export function ButtonLink({
  href,
  variant = "filled",
  glow = false,
  children,
  className = "",
}: {
  href: string;
  variant?: "filled" | "tonal";
  glow?: boolean;
  children: ReactNode;
  className?: string;
}) {
  const styles =
    variant === "filled"
      ? "bg-fg text-bg hover:bg-white active:scale-[0.98]"
      : "bg-surface-3 text-fg hover:bg-surface-4 active:scale-[0.98]";
  const external = href.startsWith("http");
  return (
    <Link
      href={href}
      {...(external ? { target: "_blank", rel: "noopener noreferrer" } : {})}
      className={`group relative inline-flex h-13 cursor-pointer items-center justify-center gap-2.5 rounded-full px-7 text-[15px] font-semibold transition-all duration-200 hover:-translate-y-0.5 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-fg-2 ${styles} ${
        glow ? "glow-cta" : ""
      } ${className}`}
    >
      {children}
    </Link>
  );
}

export function Chip({
  icon,
  children,
  tone = "default",
}: {
  icon?: ReactNode;
  children: ReactNode;
  tone?: "default" | "green";
}) {
  return (
    <span
      className={`inline-flex items-center gap-1.5 rounded-full px-3.5 py-1.5 text-[13px] font-medium ${
        tone === "green" ? "bg-green/10 text-green" : "bg-surface-3 text-fg-2"
      }`}
    >
      {icon}
      {children}
    </span>
  );
}

export function IconBadge({
  children,
  size = "md",
  tone = "tonal",
}: {
  children: ReactNode;
  size?: "sm" | "md" | "lg";
  tone?: "tonal" | "raised";
}) {
  const sizes = {
    sm: "size-10 [&_svg]:size-4.5",
    md: "size-13 [&_svg]:size-5.5",
    lg: "size-16 [&_svg]:size-7",
  };
  return (
    <span
      className={`inline-flex shrink-0 items-center justify-center rounded-full text-fg transition-colors duration-300 group-hover:bg-badge group-hover:text-cyan ${
        tone === "raised" ? "bg-badge" : "bg-surface-3"
      } ${sizes[size]}`}
    >
      {children}
    </span>
  );
}

export function SectionHeading({
  eyebrow,
  title,
  lead,
}: {
  eyebrow?: string;
  title: string;
  lead?: string;
}) {
  return (
    <div className="mx-auto max-w-2xl text-center">
      {eyebrow && (
        <p className="text-link-gradient mb-3 text-[13px] font-semibold tracking-[0.14em] uppercase">
          {eyebrow}
        </p>
      )}
      <h2 className="text-3xl font-bold tracking-tight text-balance sm:text-4xl">
        {title}
      </h2>
      {lead && (
        <p className="mt-4 text-[17px] leading-relaxed text-fg-2 text-pretty">
          {lead}
        </p>
      )}
    </div>
  );
}

export function StatusDot({
  tone = "green",
  pulse = false,
}: {
  tone?: "green" | "amber";
  pulse?: boolean;
}) {
  return (
    <span
      aria-hidden
      className={`inline-block size-2 rounded-full ${
        tone === "green" ? "bg-green" : "bg-amber"
      } ${pulse ? "dot-pulse" : ""}`}
    />
  );
}
