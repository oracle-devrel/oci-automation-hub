/* Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved. */
/* The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/ */

"use client";

import { FormEvent, useEffect, useRef, useState } from "react";

type Message = {
  id: string;
  role: "agent" | "user" | "system";
  text: string;
  time: string;
  imageName?: string;
  audioUrl?: string;
  voice?: string;
};

const API_URL = process.env.NEXT_PUBLIC_AGENT_API_URL ?? "";
const welcomeMessage: Message = {
  id: "welcome",
  role: "agent",
  text: "Hi! Upload a photo of your vehicle plate or tell me your registration number to get started.",
  time: "Just now",
};

function now() {
  return new Intl.DateTimeFormat([], { hour: "numeric", minute: "2-digit" }).format(new Date());
}

function newSessionId() {
  return globalThis.crypto?.randomUUID?.() ?? `web-${Date.now()}-${Math.random().toString(16).slice(2)}`;
}

function audioUrlFromPayload(payload: { audio_base64?: string; audio_mime?: string }) {
  if (!payload.audio_base64) return undefined;
  return `data:${payload.audio_mime || "audio/mpeg"};base64,${payload.audio_base64}`;
}

async function errorMessage(response: Response) {
  try {
    const payload = await response.json();
    return payload.detail || "Something went wrong. Please try again.";
  } catch {
    return "Something went wrong. Please try again.";
  }
}

export default function Home() {
  const [sessionId, setSessionId] = useState("");
  const [messages, setMessages] = useState<Message[]>([welcomeMessage]);
  const [input, setInput] = useState("");
  const [busy, setBusy] = useState(false);
  const [online, setOnline] = useState<boolean | null>(null);
  const [registration, setRegistration] = useState<string | null>(null);
  const [lastUpload, setLastUpload] = useState<string | null>(null);
  const [listening, setListening] = useState(false);
  const [voiceStatus, setVoiceStatus] = useState("Victoria ready");
  const [autoSpeak, setAutoSpeak] = useState(true);
  const messagesEnd = useRef<HTMLDivElement>(null);
  const recorder = useRef<MediaRecorder | null>(null);
  const recordingChunks = useRef<Blob[]>([]);
  const activeAudio = useRef<HTMLAudioElement | null>(null);

  useEffect(() => {
    setSessionId(newSessionId());
    fetch(`${API_URL}/health`)
      .then((response) => setOnline(response.ok))
      .catch(() => setOnline(false));
  }, []);

  useEffect(() => {
    messagesEnd.current?.scrollIntoView({ behavior: "smooth", block: "nearest" });
  }, [messages, busy]);

  function addMessage(message: Omit<Message, "id" | "time">) {
    setMessages((current) => [
      ...current,
      { ...message, id: `${Date.now()}-${Math.random()}`, time: now() },
    ]);
  }

  async function playAudio(audioUrl: string, voice = "Victoria") {
    activeAudio.current?.pause();
    const audio = new Audio(audioUrl);
    activeAudio.current = audio;
    setVoiceStatus(`${voice} speaking`);
    audio.onended = () => {
      activeAudio.current = null;
      setVoiceStatus("Victoria ready");
    };
    audio.onerror = () => {
      activeAudio.current = null;
      setVoiceStatus("Audio playback unavailable");
    };
    await audio.play().catch(() => setVoiceStatus("Use Listen again to hear the reply"));
  }

  async function sendMessage(text: string) {
    const trimmed = text.trim();
    if (!trimmed || busy || !sessionId) return;
    addMessage({ role: "user", text: trimmed });
    setInput("");
    setBusy(true);
    try {
      const response = await fetch(`${API_URL}/api/chat`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ session_id: sessionId, message: trimmed }),
      });
      if (!response.ok) throw new Error(await errorMessage(response));
      const payload = await response.json();
      const audioUrl = audioUrlFromPayload(payload);
      addMessage({ role: "agent", text: payload.reply, audioUrl, voice: payload.voice });
      if (audioUrl && autoSpeak) void playAudio(audioUrl, payload.voice);
      setOnline(true);
    } catch (error) {
      setOnline(false);
      addMessage({
        role: "system",
        text: error instanceof Error ? error.message : "The agent is unavailable. Please try again.",
      });
    } finally {
      setBusy(false);
    }
  }

  function submit(event: FormEvent) {
    event.preventDefault();
    void sendMessage(input);
  }

  async function uploadVehicle(file: File) {
    if (busy || !sessionId) return;
    setLastUpload(file.name);
    addMessage({ role: "user", text: "Uploaded a vehicle image", imageName: file.name });
    setBusy(true);
    const form = new FormData();
    form.append("image", file);
    try {
      const response = await fetch(
        `${API_URL}/api/vehicle?session_id=${encodeURIComponent(sessionId)}`,
        { method: "POST", body: form },
      );
      if (!response.ok) throw new Error(await errorMessage(response));
      const payload = await response.json();
      if (payload.registration && payload.registration !== "NOT_FOUND") {
        setRegistration(payload.registration);
      }
      const audioUrl = audioUrlFromPayload(payload);
      addMessage({ role: "agent", text: payload.reply, audioUrl, voice: payload.voice });
      if (audioUrl && autoSpeak) void playAudio(audioUrl, payload.voice);
      setOnline(true);
    } catch (error) {
      setOnline(false);
      addMessage({
        role: "system",
        text: error instanceof Error ? error.message : "The image could not be processed.",
      });
    } finally {
      setBusy(false);
    }
  }

  async function sendVoice(blob: Blob) {
    setBusy(true);
    setVoiceStatus("Transcribing your order…");
    const form = new FormData();
    form.append("audio", blob, blob.type.includes("ogg") ? "order.ogg" : "order.webm");
    try {
      const response = await fetch(
        `${API_URL}/api/voice?session_id=${encodeURIComponent(sessionId)}`,
        { method: "POST", body: form },
      );
      if (!response.ok) throw new Error(await errorMessage(response));
      const payload = await response.json();
      const audioUrl = audioUrlFromPayload(payload);
      addMessage({ role: "user", text: payload.transcript });
      addMessage({ role: "agent", text: payload.reply, audioUrl, voice: payload.voice });
      if (audioUrl && autoSpeak) await playAudio(audioUrl, payload.voice);
      setOnline(true);
    } catch (error) {
      setOnline(false);
      setVoiceStatus("Voice unavailable");
      addMessage({
        role: "system",
        text: error instanceof Error ? error.message : "The voice request could not be processed.",
      });
    } finally {
      setBusy(false);
    }
  }

  async function toggleRecording() {
    if (listening) {
      recorder.current?.stop();
      setListening(false);
      setVoiceStatus("Preparing audio…");
      return;
    }
    if (busy || !sessionId) return;
    if (!navigator.mediaDevices?.getUserMedia || typeof MediaRecorder === "undefined") {
      addMessage({ role: "system", text: "Microphone recording is not supported in this browser." });
      return;
    }
    try {
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
      const mimeType = MediaRecorder.isTypeSupported("audio/webm;codecs=opus")
        ? "audio/webm;codecs=opus"
        : MediaRecorder.isTypeSupported("audio/ogg;codecs=opus")
          ? "audio/ogg;codecs=opus"
          : "";
      recordingChunks.current = [];
      const mediaRecorder = new MediaRecorder(stream, mimeType ? { mimeType } : undefined);
      recorder.current = mediaRecorder;
      mediaRecorder.ondataavailable = (event) => {
        if (event.data.size) recordingChunks.current.push(event.data);
      };
      mediaRecorder.onstop = () => {
        stream.getTracks().forEach((track) => track.stop());
        const blob = new Blob(recordingChunks.current, { type: mediaRecorder.mimeType || "audio/webm" });
        recordingChunks.current = [];
        if (blob.size) void sendVoice(blob);
      };
      mediaRecorder.start();
      setListening(true);
      setVoiceStatus("Listening… tap again to send");
    } catch {
      setVoiceStatus("Microphone permission needed");
      addMessage({ role: "system", text: "Allow microphone access to place an order by voice." });
    }
  }

  async function resetConversation() {
    if (busy) return;
    const oldSession = sessionId;
    setSessionId(newSessionId());
    setMessages([welcomeMessage]);
    setRegistration(null);
    setLastUpload(null);
    setVoiceStatus("Victoria ready");
    activeAudio.current?.pause();
    activeAudio.current = null;
    if (oldSession) {
      fetch(`${API_URL}/api/reset`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ session_id: oldSession }),
      }).catch(() => undefined);
    }
  }

  return (
    <main className="app-shell">
      <section className="drive-panel" aria-label="Drive-thru ordering assistant">
        <header className="topbar">
          <div className="brand-lockup">
            <div className="brand-mark" aria-hidden="true">F</div>
            <div>
              <p className="eyebrow">FSTech Drive-Thru</p>
              <h1>Order with your personal food concierge</h1>
            </div>
          </div>
          <div className={`status-pill ${online === false ? "offline" : ""}`}>
            <span /> {online === null ? "Connecting" : online ? "Agent online" : "Agent offline"}
          </div>
        </header>

        <div className="workspace">
          <aside className="lane-card">
            <p className="eyebrow">Now serving</p>
            <div className="lane-number">01</div>
            <p className="lane-copy">Personalized picks based on your favorites, offers, and today&apos;s weather.</p>
            <div className="feature-list">
              <div><span>◌</span><p><strong>Vehicle recognition</strong><small>Upload a plate photo</small></p></div>
              <div><span>✦</span><p><strong>Smart recommendations</strong><small>History, weather & offers</small></p></div>
              <div><span>✓</span><p><strong>Safe checkout</strong><small>You always confirm first</small></p></div>
              <div><span>♪</span><p><strong>Victoria voice</strong><small>Speak and hear every turn</small></p></div>
            </div>
          </aside>

          <section className="conversation">
            <div className="conversation-heading">
              <div>
                <p className="eyebrow">Live order</p>
                <h2>Welcome to FSTech</h2>
              </div>
              <button className="quiet-button" type="button" onClick={resetConversation}>Start over</button>
            </div>

            <div className="messages" aria-live="polite" aria-busy={busy}>
              {messages.map((message) => (
                <div className={`message ${message.role}-message`} key={message.id}>
                  {message.role === "agent" && <div className="avatar">F</div>}
                  <div className="bubble">
                    {message.imageName && <span className="image-chip">▧ {message.imageName}</span>}
                    <p>{message.text}</p>
                    {message.role === "agent" && message.audioUrl && (
                      <button
                        className="listen-button"
                        type="button"
                        onClick={() => playAudio(message.audioUrl!, message.voice)}
                      >
                        <span aria-hidden="true">▶</span> Listen again · {message.voice || "Victoria"}
                      </button>
                    )}
                    <time>{message.time}</time>
                  </div>
                </div>
              ))}
              {busy && (
                <div className="message agent-message thinking-message">
                  <div className="avatar">F</div>
                  <div className="bubble"><span /><span /><span /></div>
                </div>
              )}
              <div ref={messagesEnd} />
            </div>

            {messages.length === 1 && (
              <div className="suggestions" aria-label="Suggested replies">
                <button type="button" onClick={() => sendMessage("Show me today's offers")}>Show today&apos;s offers</button>
                <button type="button" onClick={() => sendMessage("Recommend a meal for today")}>Recommend a meal</button>
              </div>
            )}

            <form className={`composer ${listening ? "is-listening" : ""}`} onSubmit={submit}>
              <label className="upload-button" aria-label="Upload vehicle image">
                <input
                  type="file"
                  accept="image/jpeg,image/png,image/webp"
                  disabled={busy}
                  onChange={(event) => {
                    const file = event.target.files?.[0];
                    if (file) void uploadVehicle(file);
                    event.target.value = "";
                  }}
                />
                <span aria-hidden="true">＋</span>
              </label>
              <button
                className="mic-button"
                type="button"
                aria-label={listening ? "Stop recording and send" : "Speak your order"}
                aria-pressed={listening}
                disabled={busy && !listening}
                onClick={toggleRecording}
              >
                <span aria-hidden="true">{listening ? "■" : "●"}</span>
              </button>
              <input
                aria-label="Message"
                placeholder="Type your order or ask for recommendations…"
                value={input}
                disabled={busy}
                onChange={(event) => setInput(event.target.value)}
              />
              <button className="send-button" type="submit" aria-label="Send message" disabled={busy || !input.trim()}>➜</button>
            </form>
            <p className="privacy-note">Your order is only placed after you explicitly confirm it.</p>
          </section>

          <aside className="order-card">
            <div className="order-heading">
              <p className="eyebrow">Visit details</p>
              <span>{registration ? "Recognized" : "New visit"}</span>
            </div>
            <div className="visit-details">
              <div className="detail-row"><span>Agent</span><strong>{online ? "Connected" : "Checking"}</strong></div>
              <div className="detail-row"><span>Registration</span><strong>{registration ?? "Not provided"}</strong></div>
              <div className="detail-row"><span>Last upload</span><strong>{lastUpload ?? "None"}</strong></div>
              <div className="detail-row"><span>Voice</span><strong>{voiceStatus}</strong></div>
              <div className="detail-row voice-setting">
                <span>Reply audio</span>
                <button type="button" aria-pressed={autoSpeak} onClick={() => setAutoSpeak((value) => !value)}>
                  {autoSpeak ? "Auto-play on" : "Auto-play off"}
                </button>
              </div>
            </div>
            <div className="empty-order">
              <div aria-hidden="true">⌁</div>
              <h3>Order in conversation</h3>
              <p>The agent tracks items and will show an itemized total before checkout.</p>
            </div>
            <div className="confirmation-card"><span>✓</span><p><strong>Confirmation protected</strong><small>No order is placed without your approval.</small></p></div>
          </aside>
        </div>
      </section>
    </main>
  );
}
