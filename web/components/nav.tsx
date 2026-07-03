"use client";

import Image from "next/image";
import Link from "next/link";
import { usePathname } from "next/navigation";
import { useState } from "react";
import { GITHUB_URL, RELEASES_URL } from "@/lib/links";
import { DownloadIcon, GithubIcon } from "./icons";
import { ThemeToggle } from "./theme-toggle";

const LINKS = [
  { href: "/how-it-works", label: "How it works" },
  { href: "/get-started", label: "Get started" },
  { href: "/about", label: "About" },
];

export function Nav() {
  const pathname = usePathname();
  const [open, setOpen] = useState(false);

  return (
    <header className="sticky top-0 z-50 border-b border-line bg-bg/80 backdrop-blur-xl">
      <nav
        aria-label="Main"
        className="mx-auto flex h-16 max-w-6xl items-center gap-6 px-5 sm:px-8"
      >
        <Link
          href="/"
          className="flex items-center gap-3 rounded-full focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-fg-2"
          onClick={() => setOpen(false)}
        >
          <Image
            src="/icon.png"
            alt=""
            width={36}
            height={36}
            className="size-9"
            priority
          />
          <span className="text-[15px] font-bold tracking-tight">
            Link to macOS
          </span>
        </Link>

        <ul className="ml-4 hidden items-center gap-1 md:flex">
          {LINKS.map(({ href, label }) => {
            const active = pathname === href;
            return (
              <li key={href}>
                <Link
                  href={href}
                  aria-current={active ? "page" : undefined}
                  className={`rounded-full px-4 py-2 text-[14px] font-medium transition-colors duration-200 ${
                    active
                      ? "bg-surface-3 text-fg"
                      : "text-fg-2 hover:bg-surface-2 hover:text-fg"
                  }`}
                >
                  {label}
                </Link>
              </li>
            );
          })}
        </ul>

        <div className="ml-auto flex items-center gap-2.5">
          <ThemeToggle />
          <a
            href={GITHUB_URL}
            target="_blank"
            rel="noopener noreferrer"
            aria-label="View source on GitHub"
            className="flex size-10 items-center justify-center rounded-full text-fg-2 transition-colors duration-200 hover:bg-surface-2 hover:text-fg"
          >
            <GithubIcon className="size-5" />
          </a>
          <a
            href={RELEASES_URL}
            target="_blank"
            rel="noopener noreferrer"
            className="hidden h-10 items-center gap-2 rounded-full bg-fg px-5 text-[14px] font-semibold text-bg transition-all duration-200 hover:bg-fg/90 active:scale-[0.98] sm:inline-flex"
          >
            <DownloadIcon className="size-4" />
            Download
          </a>
          <button
            type="button"
            aria-expanded={open}
            aria-label={open ? "Close menu" : "Open menu"}
            onClick={() => setOpen((v) => !v)}
            className="flex size-10 cursor-pointer items-center justify-center rounded-full text-fg-2 transition-colors duration-200 hover:bg-surface-2 hover:text-fg md:hidden"
          >
            <svg
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              strokeWidth={2}
              strokeLinecap="round"
              className="size-5"
              aria-hidden
            >
              {open ? (
                <path d="M18 6 6 18M6 6l12 12" />
              ) : (
                <path d="M4 7h16M4 12h16M4 17h16" />
              )}
            </svg>
          </button>
        </div>
      </nav>

      {open && (
        <div className="border-t border-line px-5 pt-2 pb-4 md:hidden">
          <ul className="flex flex-col gap-1">
            {LINKS.map(({ href, label }) => (
              <li key={href}>
                <Link
                  href={href}
                  onClick={() => setOpen(false)}
                  aria-current={pathname === href ? "page" : undefined}
                  className={`block rounded-2xl px-4 py-3 text-[15px] font-medium ${
                    pathname === href
                      ? "bg-surface-3 text-fg"
                      : "text-fg-2 hover:bg-surface-2"
                  }`}
                >
                  {label}
                </Link>
              </li>
            ))}
            <li className="mt-2">
              <a
                href={RELEASES_URL}
                target="_blank"
                rel="noopener noreferrer"
                className="flex h-12 items-center justify-center gap-2 rounded-full bg-fg text-[15px] font-semibold text-bg"
              >
                <DownloadIcon className="size-4" />
                Download
              </a>
            </li>
          </ul>
        </div>
      )}
    </header>
  );
}
