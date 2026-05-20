async function fetchAsset(context, assetPath, url) {
  let response = await context.env.ASSETS.fetch(
    new Request(new URL(assetPath, url.origin).toString(), context.request)
  );

  if ([301, 302, 307, 308].includes(response.status)) {
    const location = response.headers.get("Location");

    if (location) {
      const followUrl = new URL(location, url.origin);

      response = await context.env.ASSETS.fetch(
        new Request(followUrl.toString(), context.request)
      );
    }
  }

  return response;
}

async function loadDomainMap(context, url) {
  const response = await context.env.ASSETS.fetch(
    new Request(new URL("/_batch/domain-map.json", url.origin).toString(), context.request)
  );

  if (!response.ok) {
    return {};
  }

  return await response.json();
}

export async function onRequest(context) {
  const url = new URL(context.request.url);
  const host = url.hostname.toLowerCase().replace(/^www\./, "");
  let pathname = url.pathname || "/";

  // Preview mode on *.pages.dev
  if (host.endsWith(".pages.dev")) {
    let assetPath = pathname;

    if (assetPath === "/") {
      assetPath = "/_batch/index.html";
    }

    if (assetPath.endsWith("/")) {
      assetPath += "index.html";
    }

    return fetchAsset(context, assetPath, url);
  }

  const domainMap = await loadDomainMap(context, url);
  const slug = domainMap[host];

  if (!slug) {
    return new Response(`Unsupported host: ${host}`, { status: 404 });
  }

  if (pathname.startsWith("/sites/")) {
    pathname = "/";
  }

  let assetPath;

  if (pathname === "/") {
    assetPath = `/${slug}/index.html`;
  } else if (pathname === `/${slug}` || pathname === `/${slug}/`) {
    assetPath = `/${slug}/index.html`;
  } else if (pathname.startsWith(`/${slug}/`)) {
    assetPath = pathname;

    if (assetPath.endsWith("/")) {
      assetPath += "index.html";
    }
  } else {
    assetPath = `/${slug}${pathname}`;

    if (assetPath.endsWith("/")) {
      assetPath += "index.html";
    }
  }

  return fetchAsset(context, assetPath, url);
}
