/*
 * Steady - email to staff: device-link codes and notices about their own account (a reset, a
 * lock, a new device). Never to patients and never about patients: an inbox can be shared, and
 * an email is not the place for anything clinical.
 *
 * Settings come from the server's .env, never the database:
 *   STEADY_SMTP_HOST, STEADY_SMTP_PORT (587), STEADY_SMTP_USER, STEADY_SMTP_PASSWORD,
 *   STEADY_SMTP_TLS (on for port 465; 587 upgrades with STARTTLS),
 *   STEADY_MAIL_FROM (noreply@steadyapp.co.za), STEADY_MAIL_NAME (Steady)
 * Uses PocketBase globals.
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

function env(k, d) {
  var v = $os.getenv(k);
  return v === undefined || v === null || v === "" ? d : String(v);
}

/** True when the server has email settings. */
function ready() {
  return env("STEADY_SMTP_HOST", "") !== "";
}

/** Copies the .env settings into PocketBase's in-memory settings (not saved to the database). */
function configure(app) {
  if (!ready()) return false;
  var st = app.settings();
  var port = Number(env("STEADY_SMTP_PORT", "587")) || 587;
  st.smtp.enabled = true;
  st.smtp.host = env("STEADY_SMTP_HOST", "");
  st.smtp.port = port;
  st.smtp.username = env("STEADY_SMTP_USER", "");
  st.smtp.password = env("STEADY_SMTP_PASSWORD", "");
  st.smtp.tls = env("STEADY_SMTP_TLS", port === 465 ? "on" : "off") === "on";
  st.meta.senderAddress = env("STEADY_MAIL_FROM", "noreply@steadyapp.co.za");
  st.meta.senderName = env("STEADY_MAIL_NAME", "Steady");
  return true;
}

function esc(t) {
  return String(t).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

/** Sends a plain email. Returns true when the mail server took it. Never throws. */
function send(app, to, subject, text) {
  if (!configure(app)) return false;
  try {
    var st = app.settings();
    var msg = new MailerMessage({
      from: { address: st.meta.senderAddress, name: st.meta.senderName },
      to: [{ address: String(to) }],
      subject: String(subject),
      text: String(text),
      html: "<div style=\"font-family:sans-serif;font-size:15px;line-height:1.5;white-space:pre-wrap\">" + esc(text) + "</div>"
    });
    app.newMailClient().send(msg);
    return true;
  } catch (err) {
    console.log("steady mail: couldn't send to the mail server: " + err);
    return false;
  }
}

var FOOTER = "\n\nThis is an automatic message from Steady. Nothing about patients is ever sent by email.";

/** A notice to a staff member about their own account; adds who to contact if it wasn't them. */
function notice(app, user, subject, lines) {
  var name = user.getString("name") || "there";
  var text = "Hi " + name + ",\n\n" + lines.join("\n") +
    "\n\nIf this wasn't you or you didn't expect it, open Steady and choose \"Lost your phone? Lock your account\" on the sign-in screen, then contact OpenWorks IT support." + FOOTER;
  return send(app, user.email(), "Steady: " + subject, text);
}

module.exports = { ready: ready, configure: configure, send: send, notice: notice, FOOTER: FOOTER };
