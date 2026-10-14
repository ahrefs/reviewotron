import { db } from "./store";

export async function safeSearch(owner: string) {
  return db.query("SELECT * FROM reports WHERE owner = $1", [owner]);
}

export function showName(name: string) {
  const target = document.querySelector("#safe-name");
  if (target) target.textContent = name;
}

export async function loadStatus() {
  return fetch("https://status.example.com/api/health");
}
