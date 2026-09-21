"""Lambda entry point - the incident orchestration layer.

Mirrors the customer's existing shape: the Lambda is triggered by an incident
event, keeps owning the workflow, and now calls Bedrock with a tool-calling loop
so Claude can pull Operata evidence through AgentCore Gateway before it writes
its troubleshooting summary.
"""

import json
import logging
import os

from incident_agent import run_incident_analysis

log = logging.getLogger()
log.setLevel(os.environ.get("LOG_LEVEL", "INFO"))


def _build_prompt(event):
    """Turn an incident event into the analyst brief.

    Accepts either a free-form {"prompt": "..."} or a structured incident
    payload of the kind a threshold alarm would produce.
    """
    if event.get("prompt"):
        return event["prompt"]

    incident = event.get("incident", event)
    lines = ["A contact-centre incident has been raised. Investigate it using the Operata tools.", ""]
    for label, key in [
        ("Incident ID", "id"),
        ("Title", "title"),
        ("Detected at", "detectedAt"),
        ("Severity", "severity"),
        ("Metric", "metric"),
        ("Observed value", "observedValue"),
        ("Threshold", "threshold"),
        ("Time window", "window"),
        ("Affected agents", "affectedAgents"),
        ("Contact IDs", "contactIds"),
        ("Notes", "notes"),
    ]:
        value = incident.get(key)
        if value not in (None, "", [], {}):
            lines.append(f"{label}: {json.dumps(value) if isinstance(value, (list, dict)) else value}")

    if len(lines) == 2:
        lines.append("No structured detail was supplied. Establish current voice-quality health "
                     "over the last 24 hours and report anything anomalous.")
    return "\n".join(lines)


def handler(event, context):
    log.info("Incident event received: %s", json.dumps(event)[:2000])
    prompt = _build_prompt(event)

    try:
        result = run_incident_analysis(prompt)
    except Exception as exc:
        log.exception("Incident analysis failed")
        return {"statusCode": 500, "body": json.dumps({"error": str(exc)})}

    log.info(
        "Analysis complete in %s turns using %s tool calls",
        result["turns"], len(result["tool_calls"]),
    )

    # In the customer's pipeline this return value is what feeds the MS Teams
    # bot notification and the email to the TSE.
    return {
        "statusCode": 200,
        "body": json.dumps(
            {
                "troubleshooting": result["answer"],
                "toolCalls": result["tool_calls"],
                "turns": result["turns"],
                "usage": result["usage"],
            }
        ),
    }
