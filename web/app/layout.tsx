import type { Metadata } from "next";
import { Geist_Mono, Roboto_Flex, Inter } from "next/font/google";
import { Footer } from "@/components/footer";
import { Nav } from "@/components/nav";
import "./globals.css";
import { cn } from "@/lib/utils";

const inter = Inter({ subsets: ["latin"], variable: "--font-sans" });

const robotoFlex = Roboto_Flex({
  variable: "--font-roboto-flex",
  subsets: ["latin"],
});

const geistMono = Geist_Mono({
  variable: "--font-geist-mono",
  subsets: ["latin"],
});

export const metadata: Metadata = {
  title: {
    default: "Link to macOS — your phone and your Mac, linked",
    template: "%s · Link to macOS",
  },
  description:
    "Self-hosted phone↔Mac link: two-way clipboard sync, remote lock, proximity auto-lock, live battery, notification and SMS mirroring. Your Wi-Fi or your own relay — no third party.",
  abstract:
    "Self-hosted phone↔Mac link: two-way clipboard sync, remote lock, proximity auto-lock, live battery, notification and SMS mirroring. Your Wi-Fi or your own relay — no third party.",
  applicationName: "Link to macOS",
  authors: [{ name: "Link to macOS", url: "https://linktomac.com" }],
  creator: "Link to macOS",
  publisher: "grkndev",
  keywords: [
    "phone link",
    "link to windows",
    "link",
    "macos",
    "phone",
    "sync",
    "clipboard",
    "notifications",
    "sms",
    "remote lock",
    "battery",
    "proximity lock",
    "self-hosted",
    "open source",
  ],
  openGraph: {
    title: "Link to macOS — your phone and your Mac, linked",
    description:
      "Self-hosted phone↔Mac link: two-way clipboard sync, remote lock, proximity auto-lock, live battery, notification and SMS mirroring. Your Wi-Fi or your own relay — no third party.",
    url: "https://linktomac.com",
    siteName: "Link to macOS",
    images: [
      {
        url: "/og.png",
        width: 1200,
        height: 630,
      },
    ],
    locale: "en_US",
    type: "website",
  },
  twitter: {
    card: "summary_large_image",
    title: "Link to macOS — your phone and your Mac, linked",
    description:
      "Self-hosted phone↔Mac link: two-way clipboard sync, remote lock, proximity auto-lock, live battery, notification and SMS mirroring. Your Wi-Fi or your own relay — no third party.",
    images: ["/og.png"],
    creator: "@grkndev",
    site: "@grkndev",
  },
  robots: {
    index: true,
    follow: true,
    nocache: true,
    googleBot: {
      index: true,
      follow: true,
      noimageindex: true,
      "max-video-preview": -1,
      "max-image-preview": "large",
      "max-snippet": -1,
    },
  },
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html
      lang="en"
      className={cn(
        "h-full",
        "antialiased",
        robotoFlex.variable,
        geistMono.variable,
        "font-sans",
        inter.variable,
      )}
    >
      <body className="flex min-h-full flex-col">
        <Nav />
        <main className="flex-1">{children}</main>
        <Footer />
      </body>
    </html>
  );
}
