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

  if (Array.isArray(value)) {
    return value
      .map((item) => cleanText(item))
      .filter(Boolean)
      .join(", ");
  }

  if (typeof value === "object") {
    return JSON.stringify(value);
  }

  return String(value).trim();
}

function cleanBool(value) {
  return value === true || value === "true" || value === 1 || value === "1";
}

function normalizeUrl(value) {
  const raw = cleanText(value);

  if (!raw) return "";
  if (/^https?:\/\//i.test(raw)) return raw;

  if (raw.includes(".") && !raw.includes(" ")) {
    return `https://${raw}`;
  }

  return raw;
}

function safeDate(value) {
  const raw = cleanText(value);
  if (!raw) return new Date().toISOString();

  const date = new Date(raw);
  if (Number.isNaN(date.getTime())) return new Date().toISOString();

  return date.toISOString();
}

function compactAirtableFields(fields) {
  const cleaned = {};

  Object.entries(fields).forEach(([key, value]) => {
    if (value === undefined || value === null) return;

    if (typeof value === "string") {
      const trimmed = value.trim();
      if (!trimmed) return;
      cleaned[key] = trimmed;
      return;
    }

    cleaned[key] = value;
  });

  return cleaned;
}

function listText(value) {
  if (Array.isArray(value)) {
    return value
      .map((item) => cleanText(item))
      .filter(Boolean)
      .join(", ");
  }

  return cleanText(value);
}

function buildLeadName(payload) {
  const segment = cleanText(payload.segment_label || payload.segment || "SFTY Lead");

  const product =
    cleanText(payload.selected_product) ||
    cleanText(payload.selected_use_case) ||
    listText(payload.selected_product_labels) ||
    cleanText(payload.product_or_use_case_label) ||
    "Request";

  return `${segment} — ${product}`.slice(0, 250);
}

function buildAirtableFields(payload, request) {
  const requestUrl = new URL(request.url);
  const domain = requestUrl.hostname;

  const flow = cleanText(payload.flow);

  const selectedProductLabels =
    cleanText(payload.selected_product) ||
    listText(payload.selected_product_labels) ||
    cleanText(payload.product_or_use_case_label);

  const selectedUseCaseLabels =
    cleanText(payload.selected_use_case) ||
    listText(payload.selected_product_labels) ||
    cleanText(payload.product_or_use_case_label);

  const selectedProduct =
    flow === "business"
      ? selectedProductLabels
      : cleanText(payload.selected_product);

  const selectedUseCase =
    flow !== "business"
      ? selectedUseCaseLabels
      : "";

  const phoneE164 =
    cleanText(payload.phone_e164_like) ||
    `${cleanText(payload.country_code)}${cleanText(payload.phone)}`;

  const rawPayload = {
    ...payload,

    /*
      Cloudflare / request context.
      This is important for both:
      - client-sfty: 100 domains
      - sfty-main: one main site with 1006 pages
    */
    domain,
    request_host: domain,
    user_agent: request.headers.get("user-agent") || "",
    cf_ip_country: request.headers.get("cf-ipcountry") || "",
    received_at: new Date().toISOString()
  };

  /*
    IMPORTANT:
    We only send fields that already exist in Airtable.
    Everything else from the modal is preserved inside Raw Payload.
    This prevents Airtable errors from unknown fields or empty single-select values.
  */
  return compactAirtableFields({
    "Lead Name": buildLeadName(payload),

    "Status": "New",
    "Deal Stage": "New Lead",

    "Full Name": cleanText(payload.full_name),
    "Organization Name": cleanText(payload.organization_name),
    "Job Title": cleanText(payload.job_title),
    "Email": cleanText(payload.email),
    "Phone": phoneE164,
    "WhatsApp Available": cleanBool(payload.whatsapp_available),
    "Website": normalizeUrl(payload.website),

    "Segment": cleanText(payload.segment_label),
    "Flow": flow,

    /*
      Multiple select support:
      Business → Selected Product
      Government / FIU / Partner → Selected Use Case
    */
    "Selected Product": selectedProduct,
    "Selected Use Case": selectedUseCase,

    "Country": cleanText(payload.country),
    "Volume / Scope": cleanText(payload.volume_or_scope),
    "Deployment Preference": cleanText(payload.deployment_preference),
    "Timeline": cleanText(payload.timeline),
    "Message": cleanText(payload.message),

    "Page URL": normalizeUrl(payload.page_url),
    "Page Slug": cleanText(payload.page_slug),
    "Page Template": cleanText(payload.page_template),
    "Domain": domain,
    "CTA Source": cleanText(payload.cta_source),
    "CTA Text": cleanText(payload.cta_text),
    "Submitted At": safeDate(payload.submitted_at),

    /*
      Full modal state:
      segment, flow, all selected products/use cases,
      dynamic_values, dynamic_fields, reporting_channels,
      email type, lead confidence, phone, business/gov qualification,
      consents, CTA, page data, Cloudflare context.
    */
    "Raw Payload": JSON.stringify(rawPayload, null, 2)
  });
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
