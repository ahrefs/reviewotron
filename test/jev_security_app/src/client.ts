export async function renderProfile() {
  const response = await fetch("/api/profile");
  const profile = await response.json();
  const target = document.querySelector("#display-name");
  if (target) target.innerHTML = profile.displayName;
}

export function profileApi(request: Request) {
  const cookie = request.headers.get("cookie") ?? "";
  const displayName = /displayName=([^;]+)/.exec(cookie)?.[1] ?? "anonymous";
  return Response.json({ displayName: decodeURIComponent(displayName) });
}
