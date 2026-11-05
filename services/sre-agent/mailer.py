import os
import smtplib
import logging
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
from email.mime.application import MIMEApplication

logger = logging.getLogger("sre-agent.mailer")

SENDER = os.getenv("SES_SENDER", os.getenv("SMTP_FROM", "alerts@example.com"))
AWS_REGION = os.getenv("AWS_REGION", "ap-south-1")

# SMTP fallback settings
SMTP_HOST = os.getenv("SMTP_HOST", "")
SMTP_PORT = int(os.getenv("SMTP_PORT", "587"))
SMTP_USER = os.getenv("SMTP_USER", "")
SMTP_PASS = os.getenv("SMTP_PASS", "")
SMTP_TLS = os.getenv("SMTP_TLS", "true").lower() in ("true", "1", "yes")

# auto (original behaviour: SES -> SMTP -> file) | ses | smtp | file
EMAIL_PROVIDER = os.getenv("EMAIL_PROVIDER", "auto").lower()

def build_mime_message(to: list[str], subject: str, body_html: str, attachment_html: str, filename: str) -> MIMEMultipart:
    msg = MIMEMultipart("mixed")
    msg["Subject"] = subject
    msg["From"] = SENDER
    msg["To"] = ", ".join(to)

    # HTML Body
    alt = MIMEMultipart("alternative")
    alt.attach(MIMEText("Kubernetes Incident Root Cause Analysis is attached. Open the attachment in a browser.", "plain"))
    alt.attach(MIMEText(body_html, "html"))
    msg.attach(alt)

    # Attachment
    part = MIMEApplication(attachment_html.encode("utf-8"), Name=filename)
    part["Content-Disposition"] = f'attachment; filename="{filename}"'
    msg.attach(part)
    return msg

def send_via_ses(to: list[str], msg: MIMEMultipart) -> dict:
    import boto3
    ses = boto3.client("ses", region_name=AWS_REGION)
    logger.info("Dispatching email via AWS SES to %s", to)
    return ses.send_raw_email(Source=SENDER, Destinations=to, RawMessage={"Data": msg.as_bytes()})

def send_via_smtp(to: list[str], msg: MIMEMultipart) -> dict:
    logger.info("Dispatching email via SMTP (%s:%d) to %s", SMTP_HOST, SMTP_PORT, to)
    with smtplib.SMTP(SMTP_HOST, SMTP_PORT) as server:
        if SMTP_TLS:
            server.starttls()
        if SMTP_USER and SMTP_PASS:
            server.login(SMTP_USER, SMTP_PASS)
        server.sendmail(SENDER, to, msg.as_string())
    return {"status": "sent", "provider": "smtp"}

def send_rca_email(to: list[str], subject: str, body_html: str, attachment_html: str, filename: str):
    if not to:
        logger.warning("No recipients specified for RCA email.")
        return {"status": "skipped", "reason": "no_recipients"}

    msg = build_mime_message(to, subject, body_html, attachment_html, filename)

    # Try AWS SES first if AWS credentials/IAM role exist
    if EMAIL_PROVIDER == "ses" or EMAIL_PROVIDER == "auto" and (os.getenv("AWS_EXECUTION_ENV") or os.getenv("AWS_ROLE_ARN") or os.getenv("AWS_ACCESS_KEY_ID") or os.getenv("KUBERNETES_SERVICE_HOST")):
        try:
            return send_via_ses(to, msg)
        except Exception as e:
            logger.warning("AWS SES send failed: %s. Checking SMTP configuration...", e)

    # Try SMTP if configured
    if SMTP_HOST and EMAIL_PROVIDER in ("auto", "smtp"):
        try:
            return send_via_smtp(to, msg)
        except Exception as e:
            logger.error("SMTP send failed: %s", e)

    # Fallback: persist email to disk for inspection
    preview_path = f"/tmp/{filename}.eml"
    try:
        with open(preview_path, "wb") as f:
            f.write(msg.as_bytes())
        logger.info("Saved email preview to %s (neither SES nor SMTP was reachable)", preview_path)
    except Exception:
        pass

    return {"status": "simulated", "preview": preview_path, "recipients": to}
