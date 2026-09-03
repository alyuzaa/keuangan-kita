// Migrasi satu kali akun Supabase lama dari login email ke login username.
// Jalankan hanya dari terminal tepercaya. Jangan pernah taruh service_role di frontend.

const projectUrl = String(process.env.SUPABASE_URL || "").replace(/\/$/, "");
const serviceRoleKey = String(process.env.SUPABASE_SERVICE_ROLE_KEY || "");
const usernameDomain = "users.keuangan-kita.invalid";
const usernamePattern = /^[a-z0-9](?:[a-z0-9._-]{1,28}[a-z0-9])?$/;

function stop(message) {
  console.error(`Gagal: ${message}`);
  process.exit(1);
}

if (!projectUrl.startsWith("https://") || !serviceRoleKey) {
  stop("Isi SUPABASE_URL dan SUPABASE_SERVICE_ROLE_KEY di environment terminal.");
}

const applyChanges = process.argv.includes("--apply");
const mappings = process.argv.slice(2).filter((entry) => entry !== "--apply").map((entry) => {
  const separator = entry.lastIndexOf("=");
  const oldEmail = entry.slice(0, separator).trim().toLowerCase();
  const username = entry.slice(separator + 1).trim().toLowerCase();
  if (separator < 1 || !oldEmail.includes("@")) stop(`Format mapping tidak valid: ${entry}`);
  if (username.length < 3 || username.length > 30 || !usernamePattern.test(username)) {
    stop(`Username tidak valid: ${username}`);
  }
  return { oldEmail, username, newEmail: `${username}@${usernameDomain}` };
});

if (!mappings.length) {
  stop('Tambahkan mapping, contoh: node migrate-existing-usernames.mjs "lama@gmail.com=alyuza"');
}

if (new Set(mappings.map((item) => item.username)).size !== mappings.length) {
  stop("Setiap akun harus memakai username yang berbeda.");
}

const adminHeaders = {
  apikey: serviceRoleKey,
  Authorization: `Bearer ${serviceRoleKey}`,
  "Content-Type": "application/json",
};

async function request(url, options = {}) {
  const response = await fetch(url, options);
  const responseText = await response.text();
  let payload = null;
  try {
    payload = responseText ? JSON.parse(responseText) : null;
  } catch {
    payload = { message: responseText };
  }
  if (!response.ok) {
    throw new Error(payload?.msg || payload?.message || payload?.error_description || `${response.status} ${response.statusText}`);
  }
  return payload;
}

async function patchPublicTable(table, userId, email) {
  await request(`${projectUrl}/rest/v1/${table}?user_id=eq.${encodeURIComponent(userId)}`, {
    method: "PATCH",
    headers: { ...adminHeaders, Prefer: "return=minimal" },
    body: JSON.stringify({ email }),
  });
}

const listPayload = await request(`${projectUrl}/auth/v1/admin/users?page=1&per_page=1000`, {
  headers: adminHeaders,
});
const users = Array.isArray(listPayload) ? listPayload : (listPayload?.users || []);

const resolved = mappings.map((mapping) => {
  const user = users.find((item) => String(item.email || "").toLowerCase() === mapping.oldEmail)
    || users.find((item) => String(item.email || "").toLowerCase() === mapping.newEmail);
  if (!user) stop(`Akun tidak ditemukan: ${mapping.oldEmail}`);
  const collision = users.find((item) =>
    String(item.email || "").toLowerCase() === mapping.newEmail && item.id !== user.id
  );
  if (collision) stop(`Username sudah dipakai akun lain: ${mapping.username}`);
  return { ...mapping, user };
});

console.log("UUID pengguna akan dipertahankan:");
for (const item of resolved) {
  console.log(`- ${item.oldEmail} -> ${item.username} (${item.user.id})`);
}

if (!applyChanges) {
  console.log("Pratinjau selesai; belum ada data yang diubah.");
  console.log("Jalankan ulang dengan --apply setelah semua identitas di atas dipastikan benar.");
  process.exit(0);
}

for (const item of resolved) {
  if (String(item.user.email || "").toLowerCase() !== item.newEmail) {
    await request(`${projectUrl}/auth/v1/admin/users/${encodeURIComponent(item.user.id)}`, {
      method: "PUT",
      headers: adminHeaders,
      body: JSON.stringify({
        email: item.newEmail,
        email_confirm: true,
        user_metadata: { ...(item.user.user_metadata || {}), username: item.username },
      }),
    });
  }

  await patchPublicTable("household_members", item.user.id, item.newEmail);
  await patchPublicTable("household_member_profiles", item.user.id, item.newEmail);
  console.log(`Berhasil: ${item.username}`);
}

console.log("Migrasi selesai. Password lama tetap berlaku dan seluruh UUID tetap sama.");
