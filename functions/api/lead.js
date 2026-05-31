function jsonResponse(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store"
    }
  });
}

function cleanText(value) {
  if (value === null || value === undefined) return "";
  return String(value).trim();
}

function cleanBool(value) {
  return value === true || value === "true" || value === 1 || value === "1";
}

function buildLeadName(payload) {
  const segment = cleanText(payload.segment_label || payload.segment || "SFTY Lead");
  const product =
    cleanText(payload.selected_product) ||
    cleanText(payload.selected_use_case) ||
    cleanText(payload.product_or_use_case_label) ||
    "Request";

  return `${segment} — ${product}`.slice(0, 250);
}

function safeDate(value) {
  const raw = cleanText(value);
  if (!raw) return new Date().toISOString();

  const date = new Date(raw);
  if (Number.isNaN(date.getTime())) return new Date().toISOString();

  return date.toISOString();
}

function buildAirtableFields(payload, request) {
  const requestUrl = new URL(request.url);
  const domain = requestUrl.hostname;

  const phoneE164 =
    cleanText(payload.phone_e164_like) ||
    `${cleanText(payload.country_code)}${cleanText(payload.phone)}`;

  return {
    "Lead Name": buildLeadName(payload),

    "Status": "New",
    "Deal Stage": "New Lead",

    "Full Name": cleanText(payload.full_name),
    "Organization Name": cleanText(payload.organization_name),
    "Job Title": cleanText(payload.job_title),
    "Email": cleanText(payload.email),
    "Phone": phoneE164,
    "WhatsApp Available": cleanBool(payload.whatsapp_available),
    "Website": cleanText(payload.website),

    "Segment": cleanText(payload.segment_label),
    "Flow": cleanText(payload.flow),
    "Selected Product": cleanText(payload.selected_product),
    "Selected Use Case": cleanText(payload.selected_use_case),

    "Country": cleanText(payload.country),
    "Volume / Scope": cleanText(payload.volume_or_scope),
    "Deployment Preference": cleanText(payload.deployment_preference),
    "Timeline": cleanText(payload.timeline),
    "Message": cleanText(payload.message),

    "Page URL": cleanText(payload.page_url),
    "Page Slug": cleanText(payload.page_slug),
    "Page Template": cleanText(payload.page_template),
    "Domain": domain,
    "CTA Source": cleanText(payload.cta_source),
    "CTA Text": cleanText(payload.cta_text),
    "Submitted At": safeDate(payload.submitted_at),

    "Raw Payload": JSON.stringify(
      {
        ...payload,
        domain,
        request_host: domain,
        user_agent: request.headers.get("user-agent") || "",
        cf_ip_country: request.headers.get("cf-ipcountry") || "",
        received_at: new Date().toISOString()
      },
      null,
      2
    )
  };
}

export async function onRequestOptions() {
  return jsonResponse({ ok: true });
}

export async function onRequestPost({ request, env }) {
  try {
    if (!env.AIRTABLE_TOKEN || !env.AIRTABLE_BASE_ID || !env.AIRTABLE_TABLE_ID) {
      return jsonResponse(
        {
          ok: false,
          error: "Airtable environment variables are not configured."
        },
        500
      );
    }

    let payload;

    try {
      payload = await request.json();
    } catch (error) {
      return jsonResponse(
        {
          ok: false,
          error: "Invalid JSON payload."
        },
        400
      );
    }

    const email = cleanText(payload.email);

    if (!email) {
      return jsonResponse(
        {
          ok: false,
          error: "Email is required."
        },
        400
      );
    }

    const fields = buildAirtableFields(payload, request);

    const airtableUrl = `https://api.airtable.com/v0/${env.AIRTABLE_BASE_ID}/${env.AIRTABLE_TABLE_ID}`;

    const airtableResponse = await fetch(airtableUrl, {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${env.AIRTABLE_TOKEN}`,
        "Content-Type": "application/json"
      },
      body: JSON.stringify({
        records: [
          {
            fields
          }
        ]
      })
    });

    const airtableResult = await airtableResponse.json().catch(() => ({}));

    if (!airtableResponse.ok) {
      return jsonResponse(
        {
          ok: false,
          error: "Airtable request failed.",
          details: airtableResult
        },
        500
      );
    }

    return jsonResponse({
      ok: true,
      record_id: airtableResult.records?.[0]?.id || null
    });
  } catch (error) {
    return jsonResponse(
      {
        ok: false,
        error: error && error.message ? error.message : "Unknown server error."
      },
      500
    );
  }
}

export async function onRequestGet() {
  return jsonResponse({
    ok: true,
    service: "SFTY lead endpoint",
    method: "POST /api/lead"
  });
}
