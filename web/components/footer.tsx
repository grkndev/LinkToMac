import Image from "next/image";
import Link from "next/link";
import { GITHUB_URL, RELEASES_URL } from "@/lib/links";
import { GithubIcon } from "./icons";
import { InteractiveGridPattern } from "./ui/interactive-grid-pattern";
import { cn } from "@/lib/utils";

const SITE_LINKS = [
  { href: "/", label: "Home" },
  { href: "/how-it-works", label: "How it works" },
  { href: "/get-started", label: "Get started" },
  { href: "/about", label: "About" },
];

export function Footer() {
  return (
    <footer className="mt-auto overflow-hidden border-t border-line">
      
      {/* Columns */}
      <div className="mx-auto grid max-w-6xl gap-12 px-5 py-16 sm:px-8 md:grid-cols-[1.4fr_1fr_1fr]">
        <div className="max-w-sm">
          <div className="flex items-center gap-3">
            <Image
              src="/icon.png"
              alt=""
              width={36}
              height={36}
              className="size-9"
            />
            <span className="text-2xl font-bold tracking-tight">
              Link to macOS
            </span>
          </div>
          <div className="mt-6 h-px w-40 bg-line" />
          <p className="mt-6 text-[14px] leading-relaxed text-fg-3">
            A self-hosted link between your Android phone and your Mac —
            clipboard, lock, battery, notifications and messages, with no third
            party in between.
          </p>
        </div>

        <nav aria-label="Site">
          <p className="text-[14px] font-bold tracking-tight">Site</p>
          <ul className="mt-5 space-y-3.5 text-[14px]">
            {SITE_LINKS.map(({ href, label }) => (
              <li key={href}>
                <Link
                  href={href}
                  className="text-fg-3 transition-colors duration-200 hover:text-fg"
                >
                  {label}
                </Link>
              </li>
            ))}
          </ul>
        </nav>

        <nav aria-label="Project">
          <p className="text-[14px] font-bold tracking-tight">Project</p>
          <ul className="mt-5 space-y-3.5 text-[14px]">
            <li>
              <a
                href={GITHUB_URL}
                target="_blank"
                rel="noopener noreferrer"
                className="inline-flex items-center gap-2 text-fg-3 transition-colors duration-200 hover:text-fg"
              >
                <GithubIcon className="size-4" />
                GitHub
              </a>
            </li>
            <li>
              <a
                href={RELEASES_URL}
                target="_blank"
                rel="noopener noreferrer"
                className="text-fg-3 transition-colors duration-200 hover:text-fg"
              >
                Releases
              </a>
            </li>
            <li>
              <a
                href={`${GITHUB_URL}/issues`}
                target="_blank"
                rel="noopener noreferrer"
                className="text-fg-3 transition-colors duration-200 hover:text-fg"
              >
                Report an issue
              </a>
            </li>
          </ul>
        </nav>
      </div>

      {/* Legal row */}
      <div className="mx-auto max-w-6xl px-5 sm:px-8">
        <div className="flex flex-col gap-2 border-t border-line py-6 text-[13px] text-fg-3 sm:flex-row sm:items-center sm:justify-between">
          <p>© 2026 Link to macOS · built by <Link href={"https://grkn.dev"} target="_blank" rel="linktomac.com" className="text-fg-3 hover:text-fg">grkndev</Link></p>
          <p>In the spirit of “Link to Windows” — but yours.</p>
        </div>
      </div>

      {/* Giant watermark wordmark, sinking off the bottom edge */}
      <div aria-hidden className="pointer-events-none select-none relative w-full overflow-hidden">
        <p className="translate-y-[18%] text-center text-[11.5vw] leading-none font-extrabold tracking-tighter whitespace-nowrap text-surface-2">
          Link to macOS
        </p>
      </div>
    </footer>
  );
}
