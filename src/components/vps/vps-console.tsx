"use client";

import { useEffect, useRef, useState } from "react";
import { Loader2, WifiOff } from "lucide-react";
import "xterm/css/xterm.css";

interface VpsConsoleProps {
  vpsId: number;
}

type ConnectionState = "connecting" | "connected" | "disconnected" | "expired" | "error";

const WS_URL =
  (process.env.NEXT_PUBLIC_WS_URL || "wss://api.bunkhosting.nl") +
  "/ws/console/";

export function VpsConsole({ vpsId }: VpsConsoleProps) {
  const containerRef = useRef<HTMLDivElement>(null);
  const termRef = useRef<import("xterm").Terminal | null>(null);
  const wsRef = useRef<WebSocket | null>(null);
  const fitRef = useRef<import("xterm-addon-fit").FitAddon | null>(null);
  const [state, setState] = useState<ConnectionState>("connecting");

  useEffect(() => {
    let destroyed = false;

    async function init() {
      if (!containerRef.current) return;

      // Dynamisch laden zodat xterm niet server-side wordt gerenderd
      const { Terminal } = await import("xterm");
      const { FitAddon } = await import("xterm-addon-fit");

      if (destroyed) return;

      const term = new Terminal({
        cursorBlink: true,
        scrollback: 5000,
        fontSize: 14,
        fontFamily: '"JetBrains Mono", "Fira Code", monospace',
        theme: {
          background: "#0f0f0f",
          foreground: "#d4d4d4",
          cursor: "#aeafad",
          selectionBackground: "#264f78",
          black: "#1e1e1e",
          red: "#f44747",
          green: "#6a9955",
          yellow: "#d7ba7d",
          blue: "#569cd6",
          magenta: "#c678dd",
          cyan: "#4ec9b0",
          white: "#d4d4d4",
          brightBlack: "#808080",
          brightRed: "#f44747",
          brightGreen: "#b5cea8",
          brightYellow: "#dcdcaa",
          brightBlue: "#9cdcfe",
          brightMagenta: "#c678dd",
          brightCyan: "#4ec9b0",
          brightWhite: "#ffffff",
        },
      });

      const fit = new FitAddon();
      term.loadAddon(fit);
      term.open(containerRef.current);
      fit.fit();

      termRef.current = term;
      fitRef.current = fit;

      // WebSocket verbinding openen
      const ws = new WebSocket(`${WS_URL}${vpsId}/`);
      ws.binaryType = "arraybuffer";
      wsRef.current = ws;

      ws.onopen = () => {
        if (destroyed) return;
        setState("connected");
        // Stuur initiële terminalgrootte
        sendResize(term.cols, term.rows, ws);
      };

      ws.onmessage = (e: MessageEvent) => {
        if (destroyed) return;
        term.write(new Uint8Array(e.data as ArrayBuffer));
      };

      ws.onclose = (e: CloseEvent) => {
        if (destroyed) return;
        if (e.code === 4001) {
          // JWT verlopen — aparte state zodat de UI dit duidelijk kan tonen
          setState("expired");
          term.write("\r\n\x1b[33m[Sessie verlopen — log opnieuw in]\x1b[0m\r\n");
        } else {
          setState("disconnected");
          term.write("\r\n\x1b[33m[Verbinding verbroken]\x1b[0m\r\n");
        }
      };

      ws.onerror = () => {
        if (destroyed) return;
        setState("error");
        term.write("\r\n\x1b[31m[Verbinding mislukt]\x1b[0m\r\n");
      };

      // Toetsaanslagen doorsturen naar WebSocket
      term.onData((data: string) => {
        if (ws.readyState === WebSocket.OPEN) {
          ws.send(new TextEncoder().encode(data));
        }
      });

      // Terminalgrootte aanpassen bij resize
      const observer = new ResizeObserver(() => {
        if (fitRef.current) {
          fitRef.current.fit();
          if (wsRef.current?.readyState === WebSocket.OPEN) {
            sendResize(term.cols, term.rows, wsRef.current);
          }
        }
      });
      observer.observe(containerRef.current);

      return () => observer.disconnect();
    }

    const cleanup = init();

    return () => {
      destroyed = true;
      wsRef.current?.close();
      termRef.current?.dispose();
      cleanup.then((fn) => fn?.());
    };
  }, [vpsId]);

  return (
    <div className="relative h-full w-full rounded-lg overflow-hidden bg-[#0f0f0f]">
      {state === "connecting" && (
        <div className="absolute inset-0 flex items-center justify-center z-10 bg-[#0f0f0f]">
          <div className="flex flex-col items-center gap-3 text-muted-foreground">
            <Loader2 className="h-6 w-6 animate-spin" />
            <span className="text-sm">Verbinding maken met server…</span>
          </div>
        </div>
      )}

      {state === "expired" && (
        <div className="absolute bottom-4 left-1/2 -translate-x-1/2 z-10 flex items-center gap-2 rounded-md bg-orange-900/80 px-3 py-2 text-orange-200 text-sm">
          <WifiOff className="h-4 w-4" />
          Sessie verlopen —{" "}
          <a href="/login" className="underline font-medium">
            opnieuw inloggen
          </a>
        </div>
      )}

      {state === "disconnected" && (
        <div className="absolute bottom-4 left-1/2 -translate-x-1/2 z-10 flex items-center gap-2 rounded-md bg-yellow-900/80 px-3 py-2 text-yellow-200 text-sm">
          <WifiOff className="h-4 w-4" />
          Verbinding verbroken
        </div>
      )}

      {state === "error" && (
        <div className="absolute bottom-4 left-1/2 -translate-x-1/2 z-10 flex items-center gap-2 rounded-md bg-red-900/80 px-3 py-2 text-red-200 text-sm">
          <WifiOff className="h-4 w-4" />
          Kon geen verbinding maken
        </div>
      )}

      <div ref={containerRef} className="h-full w-full p-2" />
    </div>
  );
}

function sendResize(cols: number, rows: number, ws: WebSocket) {
  ws.send(JSON.stringify({ type: "resize", cols, rows }));
}
