"use client";

import { useEffect, useRef, useState, forwardRef, useImperativeHandle } from "react";
import { Loader2, WifiOff } from "lucide-react";
import "@xterm/xterm/css/xterm.css";

export interface VpsConsoleHandle {
  sendText: (text: string) => void;
}

interface VpsConsoleProps {
  vpsId: string;
}

type ConnectionState = "connecting" | "connected" | "disconnected" | "expired" | "error" | "forbidden" | "ssh_error" | "hostkey";

const WS_URL =
  (process.env.NEXT_PUBLIC_WS_URL || "wss://api.bunkhosting.nl") +
  "/ws/console/";

export const VpsConsole = forwardRef<VpsConsoleHandle, VpsConsoleProps>(
function VpsConsole({ vpsId }, ref) {
  const containerRef = useRef<HTMLDivElement>(null);
  const termRef = useRef<import("@xterm/xterm").Terminal | null>(null);
  const wsRef = useRef<WebSocket | null>(null);
  const fitRef = useRef<import("@xterm/addon-fit").FitAddon | null>(null);
  const [state, setState] = useState<ConnectionState>("connecting");

  useImperativeHandle(ref, () => ({
    sendText: (text: string) => {
      if (wsRef.current?.readyState === WebSocket.OPEN) {
        wsRef.current.send(new TextEncoder().encode(text));
        termRef.current?.focus();
      }
    },
  }), []);

  useEffect(() => {
    let destroyed = false;

    async function init() {
      if (!containerRef.current) return;

      // Dynamisch laden zodat xterm niet server-side wordt gerenderd
      const { Terminal } = await import("@xterm/xterm");
      const { FitAddon } = await import("@xterm/addon-fit");

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
          setState("expired");
          term.write("\r\n\x1b[33m[Sessie verlopen, log opnieuw in]\x1b[0m\r\n");
        } else if (e.code === 4003 || e.code === 4403) {
          setState("forbidden");
          term.write("\r\n\x1b[31m[Geen toegang tot deze VPS]\x1b[0m\r\n");
        } else if (e.code === 4005) {
          setState("ssh_error");
          term.write("\r\n\x1b[31m[SSH-verbinding mislukt, probeer het opnieuw of neem contact op]\x1b[0m\r\n");
        } else if (e.code === 4006) {
          setState("hostkey");
          term.write("\r\n\x1b[31m[SSH host key mismatch, beveiligingscontrole gefaald]\x1b[0m\r\n");
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

      // Bijhouden of de terminal actief is (gefocust of recent aangeklikt).
      // Dit is betrouwbaarder dan document.activeElement controleren, omdat
      // rechtermuisklik en contextmenu de focus kunnen verplaatsen vóór het paste-event.
      let termActive = false;
      term.textarea?.addEventListener("focus", () => { termActive = true; });
      term.textarea?.addEventListener("blur", () => { termActive = false; });

      // Ctrl+V → voorkom dat xterm \x16 (^V) stuurt; het browser-paste-event
      // handelt de daadwerkelijke inhoud af via handlePaste hieronder.
      // navigator.clipboard.readText() wordt bewust NIET gebruikt: dat vereist
      // de "clipboard-read"-permissie die browsers standaard weigeren.
      //
      // Ctrl+Shift+C → kopieer huidige selectie naar klembord.
      term.attachCustomKeyEventHandler((e: KeyboardEvent) => {
        if (e.type !== "keydown") return true;

        if (e.ctrlKey && !e.shiftKey && !e.altKey && e.key === "v") {
          // return false voorkomt ^V in de terminal; de browser vuurt daarna
          // automatisch een paste-event op de interne textarea van xterm.
          return false;
        }

        if (e.ctrlKey && e.shiftKey && e.key === "C") {
          const selection = term.getSelection();
          if (selection) navigator.clipboard.writeText(selection).catch(() => {});
          return false;
        }

        return true;
      });

      // Rechtsklik: selectie aanwezig → kopieer naar klembord (preventDefault).
      // Geen selectie → toon native contextmenu met "Plakken".
      // Zet termActive=true zodat het paste-event dat volgt wordt verwerkt,
      // ook al heeft de browser de focus tijdelijk verschoven naar het menu.
      containerRef.current.addEventListener("contextmenu", (e: MouseEvent) => {
        const selection = term.getSelection();
        if (selection) {
          e.preventDefault();
          navigator.clipboard.writeText(selection).catch(() => {});
        } else {
          termActive = true;
        }
      });

      // Paste-event: vangt alle plak-acties op:
      //   - Ctrl+V        (browser vuurt paste na onze return-false hierboven)
      //   - Ctrl+Shift+V  (Linux/Wayland standaard)
      //   - Rechtsklik → Plakken (native contextmenu)
      //
      // stopImmediatePropagation() is cruciaal: zonder die call vuurt xterm's
      // eigen textarea-handler ook, wat via term.onData een tweede WebSocket-send
      // geeft (dubbele invoer in de terminal). Door propagation in capture-fase te
      // stoppen ziet xterm de paste-event nooit.
      //
      // We controleren termActive in plaats van document.activeElement omdat
      // het contextmenu en focuswijzigingen activeElement onbetrouwbaar maken.
      const handlePaste = (e: ClipboardEvent) => {
        if (!termActive) return;
        e.preventDefault();
        e.stopImmediatePropagation();
        const text = e.clipboardData?.getData("text/plain") ?? "";
        if (text && ws.readyState === WebSocket.OPEN) {
          ws.send(new TextEncoder().encode(text));
        }
      };
      window.addEventListener("paste", handlePaste, true);

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

      return () => {
        observer.disconnect();
        window.removeEventListener("paste", handlePaste, true);
      };
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
          Sessie verlopen,{" "}
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

      {state === "forbidden" && (
        <div className="absolute bottom-4 left-1/2 -translate-x-1/2 z-10 flex items-center gap-2 rounded-md bg-red-900/80 px-3 py-2 text-red-200 text-sm">
          <WifiOff className="h-4 w-4" />
          Geen toegang tot deze VPS
        </div>
      )}

      {state === "ssh_error" && (
        <div className="absolute bottom-4 left-1/2 -translate-x-1/2 z-10 flex items-center gap-2 rounded-md bg-red-900/80 px-3 py-2 text-red-200 text-sm">
          <WifiOff className="h-4 w-4" />
          SSH-verbinding mislukt, probeer het opnieuw
        </div>
      )}

      {state === "hostkey" && (
        <div className="absolute bottom-4 left-1/2 -translate-x-1/2 z-10 flex items-center gap-2 rounded-md bg-red-900/80 px-3 py-2 text-red-200 text-sm">
          <WifiOff className="h-4 w-4" />
          SSH host key mismatch, neem contact op
        </div>
      )}

      <div ref={containerRef} className="h-full w-full p-2" />
    </div>
  );
});

function sendResize(cols: number, rows: number, ws: WebSocket) {
  ws.send(JSON.stringify({ type: "resize", cols, rows }));
}
