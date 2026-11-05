import os, sys, tempfile

# Configure before the app modules are imported: no LLM, no cluster, no email.
os.environ.update(
    AGENT_API_KEY="test-key",
    ANTHROPIC_API_KEY="",
    EMAIL_PROVIDER="file",
    REPORT_TIMEZONE="Asia/Singapore",
    REPORT_DIR=tempfile.mkdtemp(prefix="rca-reports-"),
)
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
