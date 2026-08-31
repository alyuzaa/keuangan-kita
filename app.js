import { createClient } from "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm";
import { SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY } from "./config.js";

const $ = (selector) => document.querySelector(selector);
const $$ = (selector) => [...document.querySelectorAll(selector)];

const state = {
  user: null,
  household: null,
  transactions: [],
  assets: [],
  authMode: "login",
  transactionMode: "income",
  transactionFilter: "all",
  activeView: "dashboard",
};

const incomeCategories = ["Gaji", "Bonus", "Usaha", "Investasi", "Hadiah", "Lainnya"];
const outcomeCategories = ["Rumah tangga", "Tagihan", "Transportasi", "Kesehatan", "Belanja", "Hiburan", "Lainnya"];
const today = new Date().toISOString().slice(0, 10);

const isConfigured =
  SUPABASE_URL.startsWith("https://") &&
  !SUPABASE_URL.includes("GANTI-") &&
  SUPABASE_PUBLISHABLE_KEY.length > 30 &&
  !SUPABASE_PUBLISHABLE_KEY.includes("GANTI_");

let supabase = null;

if (!isConfigured) {
  $("#configError").classList.remove("hidden");
  $("#authScreen").classList.remove("hidden");
} else {
  supabase = createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, {
    auth: {
      persistSession: true,
      autoRefreshToken: true,
      detectSessionInUrl: true,
    },
  });
  initialize();
}

bindEvents();

async function initialize() {
  setBusy(true);
  const { data, error } = await supabase.auth.getSession();
  if (error) showToast(error.message, "error");
  await handleSession(data.session);

  supabase.auth.onAuthStateChange((event, session) => {
    setTimeout(async () => {
      if (event === "PASSWORD_RECOVERY") {
        state.user = session?.user ?? null;
        $("#passwordDialog").showModal();
        return;
      }
      if (event === "SIGNED_IN" || event === "SIGNED_OUT" || event === "USER_UPDATED") {
        await handleSession(session);
      }
    }, 0);
  });
}

async function handleSession(session) {
  state.user = session?.user ?? null;

  if (!state.user) {
    state.household = null;
    state.transactions = [];
    state.assets = [];
    showScreen("auth");
    setBusy(false);
    return;
  }

  await loadHousehold();
}

async function loadHousehold() {
  const { data, error } = await supabase
    .from("household_members")
    .select("household_id, role, households!inner(id, name, invite_code)")
    .eq("user_id", state.user.id)
    .maybeSingle();

  if (error) {
    showToast(error.message, "error");
    setBusy(false);
    return;
  }

  if (!data) {
    state.household = null;
    showScreen("household");
    setBusy(false);
    return;
  }

  state.household = {
    ...data.households,
    role: data.role,
  };

  showScreen("app");
  fillProfile();
  await loadFinanceData();
}

async function loadFinanceData() {
  setBusy(true);
  const householdId = state.household.id;
  const [transactionsResult, assetsResult] = await Promise.all([
    supabase
      .from("transactions")
      .select("*")
      .eq("household_id", householdId)
      .order("date", { ascending: false })
      .order("created_at", { ascending: false }),
    supabase
      .from("assets")
      .select("*")
      .eq("household_id", householdId)
      .order("created_at", { ascending: false }),
  ]);

  if (transactionsResult.error || assetsResult.error) {
    showToast(transactionsResult.error?.message || assetsResult.error?.message || "Data gagal dimuat.", "error");
  } else {
    state.transactions = transactionsResult.data ?? [];
    state.assets = assetsResult.data ?? [];
    renderAll();
  }
  setBusy(false);
}

function bindEvents() {
  $("#loginTab").addEventListener("click", () => setAuthMode("login"));
  $("#registerTab").addEventListener("click", () => setAuthMode("register"));
  $("#authForm").addEventListener("submit", submitAuth);
  $("#forgotPassword").addEventListener("click", resetPassword);
  $("#createHouseholdForm").addEventListener("submit", createHousehold);
  $("#joinHouseholdForm").addEventListener("submit", joinHousehold);
  $("#onboardingLogout").addEventListener("click", logout);
  $("#logoutButton").addEventListener("click", logout);
  $("#copyInviteCode").addEventListener("click", copyInviteCode);

  $$(".nav-button").forEach((button) => {
    button.addEventListener("click", () => switchView(button.dataset.view));
  });

  $("#topIncomeButton").addEventListener("click", () => openTransactionDialog("income"));
  $("#topOutcomeButton").addEventListener("click", () => openTransactionDialog("outcome"));
  $("#viewIncomeButton").addEventListener("click", () => openTransactionDialog("income"));
  $("#viewOutcomeButton").addEventListener("click", () => openTransactionDialog("outcome"));
  $("#addAssetButton").addEventListener("click", openAssetDialog);

  $("#transactionDialog .modal-close").addEventListener("click", () => $("#transactionDialog").close());
  $("#assetDialog .modal-close").addEventListener("click", () => $("#assetDialog").close());
  $("#transactionForm").addEventListener("submit", saveTransaction);
  $("#assetForm").addEventListener("submit", saveAsset);
  $("#passwordForm").addEventListener("submit", saveNewPassword);

  $$(".filter-tabs button").forEach((button) => {
    button.addEventListener("click", () => {
      state.transactionFilter = button.dataset.filter;
      $$(".filter-tabs button").forEach((item) => item.classList.toggle("active", item === button));
      renderTransactions();
    });
  });

  [
    "#transactionAmount",
    "#husbandAllocation",
    "#wifeAllocation",
    "#savingsAllocation",
    "#assetPurchaseValue",
    "#assetCurrentValue",
  ].forEach((selector) => {
    $(selector).addEventListener("input", (event) => {
      event.target.value = formatNumberInput(event.target.value);
      if (selector.includes("Allocation") || selector === "#transactionAmount") updateAllocationStatus();
    });
  });

  $("#inviteCodeInput").addEventListener("input", (event) => {
    event.target.value = event.target.value.toUpperCase().replace(/[^A-Z0-9]/g, "");
  });
}

function setAuthMode(mode) {
  state.authMode = mode;
  $("#loginTab").classList.toggle("active", mode === "login");
  $("#registerTab").classList.toggle("active", mode === "register");
  $("#authSubmit").textContent = mode === "login" ? "Masuk" : "Buat akun";
  $("#forgotPassword").classList.toggle("hidden", mode === "register");
  $("#authPassword").autocomplete = mode === "login" ? "current-password" : "new-password";
}

async function submitAuth(event) {
  event.preventDefault();
  if (!supabase) return;

  const email = $("#authEmail").value.trim().toLowerCase();
  const password = $("#authPassword").value;
  setButtonBusy($("#authSubmit"), true, state.authMode === "login" ? "Memproses…" : "Membuat akun…");

  if (state.authMode === "login") {
    const { error } = await supabase.auth.signInWithPassword({ email, password });
    if (error) showToast(translateAuthError(error.message), "error");
  } else {
    const { data, error } = await supabase.auth.signUp({
      email,
      password,
      options: { emailRedirectTo: window.location.origin },
    });
    if (error) {
      showToast(translateAuthError(error.message), "error");
    } else if (!data.session) {
      showToast("Akun dibuat. Periksa email untuk melakukan konfirmasi.");
    } else {
      showToast("Akun berhasil dibuat.");
    }
  }

  setButtonBusy($("#authSubmit"), false);
}

async function resetPassword() {
  if (!supabase) return;
  const email = $("#authEmail").value.trim().toLowerCase();
  if (!email) {
    showToast("Isi alamat email terlebih dahulu.", "error");
    $("#authEmail").focus();
    return;
  }

  const { error } = await supabase.auth.resetPasswordForEmail(email, {
    redirectTo: window.location.origin,
  });
  if (error) showToast(translateAuthError(error.message), "error");
  else showToast("Tautan reset password sudah dikirim ke email.");
}

async function saveNewPassword(event) {
  event.preventDefault();
  const password = $("#newPassword").value;
  if (password.length < 6) {
    showToast("Password minimal 6 karakter.", "error");
    return;
  }

  const button = $("#savePasswordButton");
  setButtonBusy(button, true, "Menyimpan…");
  const { error } = await supabase.auth.updateUser({ password });
  if (error) {
    showToast(translateAuthError(error.message), "error");
  } else {
    $("#passwordDialog").close();
    $("#passwordForm").reset();
    showToast("Password berhasil diperbarui.");
    const { data } = await supabase.auth.getSession();
    await handleSession(data.session);
  }
  setButtonBusy(button, false);
}

async function createHousehold(event) {
  event.preventDefault();
  const button = event.submitter;
  const name = $("#householdName").value.trim();
  if (!name) return;

  setButtonBusy(button, true, "Membuat…");
  const { error } = await supabase.rpc("create_household", { household_name: name });
  if (error) {
    showToast(error.message, "error");
  } else {
    showToast("Ruang keluarga berhasil dibuat.");
    await loadHousehold();
  }
  setButtonBusy(button, false);
}

async function joinHousehold(event) {
  event.preventDefault();
  const button = event.submitter;
  const code = $("#inviteCodeInput").value.trim().toUpperCase();
  if (code.length !== 12) {
    showToast("Kode undangan harus terdiri dari 12 karakter.", "error");
    return;
  }

  setButtonBusy(button, true, "Menghubungkan…");
  const { error } = await supabase.rpc("join_household", { invitation_code: code });
  if (error) {
    showToast(error.message.includes("not found") ? "Kode undangan tidak ditemukan." : error.message, "error");
  } else {
    showToast("Akun berhasil dihubungkan dengan pasangan.");
    await loadHousehold();
  }
  setButtonBusy(button, false);
}

async function logout() {
  if (!supabase) return;
  await supabase.auth.signOut();
  showToast("Kamu sudah keluar.");
}

function showScreen(screen) {
  $("#authScreen").classList.toggle("hidden", screen !== "auth");
  $("#householdScreen").classList.toggle("hidden", screen !== "household");
  $("#app").classList.toggle("hidden", screen !== "app");
}

function fillProfile() {
  const email = state.user.email ?? "";
  const fallbackName = email.split("@")[0] || "Pengguna";
  const name = state.user.user_metadata?.full_name || fallbackName;
  $("#userName").textContent = name;
  $("#userEmail").textContent = email;
  $("#userAvatar").textContent = name.slice(0, 1).toUpperCase();
  $("#sidebarHousehold").textContent = state.household.name;
  $("#mobileHouseholdName").textContent = state.household.name;
  $("#sidebarInviteCode").textContent = state.household.invite_code;
}

async function copyInviteCode() {
  try {
    await navigator.clipboard.writeText(state.household.invite_code);
    showToast("Kode undangan berhasil disalin.");
  } catch {
    showToast(`Kode undangan: ${state.household.invite_code}`);
  }
}

function switchView(view) {
  state.activeView = view;
  const titles = {
    dashboard: ["BERANDA KELUARGA", "Selamat datang kembali"],
    transactions: ["ARUS KEUANGAN", "Riwayat transaksi"],
    assets: ["KEKAYAAN KELUARGA", "Daftar aset"],
  };

  $$(".view").forEach((item) => item.classList.add("hidden"));
  $(`#${view}View`).classList.remove("hidden");
  $$(".nav-button").forEach((button) => button.classList.toggle("active", button.dataset.view === view));
  $("#pageEyebrow").textContent = titles[view][0];
  $("#pageTitle").textContent = titles[view][1];
}

function renderAll() {
  renderDashboard();
  renderTransactions();
  renderAssets();
  switchView(state.activeView);
}

function getTotals() {
  let income = 0;
  let outcome = 0;
  let husband = 0;
  let wife = 0;
  let savings = 0;
  let monthIncome = 0;
  let monthOutcome = 0;
  const now = new Date();
  const monthKey = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, "0")}`;

  state.transactions.forEach((item) => {
    const amount = Number(item.amount);
    if (item.type === "income") {
      income += amount;
      husband += Number(item.husband_allocation);
      wife += Number(item.wife_allocation);
      savings += Number(item.savings_allocation);
      if (item.date.startsWith(monthKey)) monthIncome += amount;
    } else {
      outcome += amount;
      if (item.source === "husband") husband -= amount;
      if (item.source === "wife") wife -= amount;
      if (item.source === "savings") savings -= amount;
      if (item.date.startsWith(monthKey)) monthOutcome += amount;
    }
  });

  const assetValue = state.assets.reduce((sum, item) => sum + Number(item.current_value), 0);
  const cash = husband + wife + savings;
  return {
    income,
    outcome,
    husband,
    wife,
    savings,
    monthIncome,
    monthOutcome,
    assetValue,
    cash,
    netWorth: cash + assetValue,
  };
}

function renderDashboard() {
  const totals = getTotals();
  $("#totalWealth").textContent = formatRupiah(totals.netWorth);
  $("#savingsBalance").textContent = formatCompactRupiah(totals.savings);
  $("#assetValue").textContent = formatCompactRupiah(totals.assetValue);
  $("#monthIncome").textContent = formatRupiah(totals.monthIncome);
  $("#monthOutcome").textContent = formatRupiah(totals.monthOutcome);
  $("#monthDifference").textContent = formatRupiah(totals.monthIncome - totals.monthOutcome);

  const allocations = [
    { label: "Uang suami", value: totals.husband, icon: "♙", color: "sage" },
    { label: "Uang istri", value: totals.wife, icon: "♡", color: "rose" },
  ];
  const max = Math.max(...allocations.map((item) => Math.max(item.value, 0)), 1);

  $("#allocationList").innerHTML = allocations.map((item) => `
    <div class="allocation-item">
      <div class="allocation-icon ${item.color}">${item.icon}</div>
      <div class="allocation-data">
        <div><span>${item.label}</span><strong>${formatRupiah(item.value)}</strong></div>
        <div class="progress"><i style="width:${Math.max(item.value, 0) / max * 100}%"></i></div>
      </div>
    </div>
  `).join("");

  const recent = state.transactions.slice(0, 5);
  $("#recentTransactions").innerHTML = recent.length
    ? recent.map(transactionRowHtml).join("")
    : emptyStateHtml("⇄", "Belum ada transaksi", "Catat income pertama untuk mulai melihat kondisi keuangan keluarga.", "income");

  const assetPreview = state.assets.slice(0, 3);
  $("#assetSnapshot").innerHTML = assetPreview.length
    ? assetPreview.map((asset) => `
      <div class="asset-preview">
        <div class="asset-symbol">${assetSymbol(asset.asset_type)}</div>
        <div><strong>${escapeHtml(asset.name)}</strong><span>${formatQuantity(asset.quantity)} ${escapeHtml(asset.unit)}</span></div>
        <b>${formatCompactRupiah(asset.current_value)}</b>
      </div>
    `).join("")
    : emptyStateHtml("◇", "Belum ada aset", "Tambahkan emas, tanah, perhiasan, kendaraan, atau aset lainnya.", "asset");

  bindDynamicActions();
}

function renderTransactions() {
  const filtered = state.transactions.filter((item) => state.transactionFilter === "all" || item.type === state.transactionFilter);
  const container = $("#transactionsTable");

  if (!filtered.length) {
    container.innerHTML = emptyStateHtml("⇄", "Belum ada transaksi", "Income dan outcome yang kalian catat akan muncul di sini.", "income");
    bindDynamicActions();
    return;
  }

  container.innerHTML = `
    <div class="table-head"><span>TRANSAKSI</span><span>TANGGAL</span><span>SUMBER/ALOKASI</span><span>NOMINAL</span><span></span></div>
    ${filtered.map((item) => `
      <div class="table-row">
        <div class="transaction-name">
          <div class="transaction-icon ${item.type}">${item.type === "income" ? "↙" : "↗"}</div>
          <div><strong>${escapeHtml(item.category)}</strong><span>${escapeHtml(item.description || (item.type === "income" ? "Pemasukan keluarga" : "Pengeluaran keluarga"))}</span></div>
        </div>
        <span>${formatDate(item.date, true)}</span>
        <span>${item.type === "income" ? "Suami · Istri · Tabungan" : sourceLabel(item.source)}</span>
        <strong class="${item.type === "income" ? "positive" : "negative"}">${item.type === "income" ? "+" : "−"}${formatRupiah(item.amount)}</strong>
        <button class="delete-button" data-delete-transaction="${item.id}" type="button" aria-label="Hapus transaksi">⌫</button>
      </div>
    `).join("")}
  `;

  $$("[data-delete-transaction]").forEach((button) => {
    button.addEventListener("click", () => deleteTransaction(button.dataset.deleteTransaction));
  });
}

function renderAssets() {
  const total = state.assets.reduce((sum, item) => sum + Number(item.current_value), 0);
  $("#assetsTotal").textContent = formatRupiah(total);
  $("#assetsCount").textContent = `${state.assets.length} aset tercatat`;

  $("#assetsGrid").innerHTML = state.assets.length
    ? state.assets.map((asset) => `
      <article class="asset-card">
        <div class="asset-card-top">
          <div class="asset-symbol">${assetSymbol(asset.asset_type)}</div>
          <button class="delete-button" data-delete-asset="${asset.id}" type="button" aria-label="Hapus aset">⌫</button>
        </div>
        <span>${escapeHtml(asset.asset_type.toUpperCase())}</span>
        <h3>${escapeHtml(asset.name)}</h3>
        <p>${formatQuantity(asset.quantity)} ${escapeHtml(asset.unit)}${asset.notes ? ` · ${escapeHtml(asset.notes)}` : ""}</p>
        <div class="asset-values">
          <div><span>Harga beli</span><strong>${formatCompactRupiah(asset.purchase_value)}</strong></div>
          <div><span>Nilai sekarang</span><strong>${formatCompactRupiah(asset.current_value)}</strong></div>
        </div>
      </article>
    `).join("")
    : emptyStateHtml("◇", "Belum ada aset", "Mulai dari emas, tanah, perhiasan, kendaraan, atau aset lainnya.", "asset");

  $$("[data-delete-asset]").forEach((button) => {
    button.addEventListener("click", () => deleteAsset(button.dataset.deleteAsset));
  });
  bindDynamicActions();
}

function transactionRowHtml(item) {
  return `
    <div class="recent-row">
      <div class="transaction-icon ${item.type}">${item.type === "income" ? "↙" : "↗"}</div>
      <div><strong>${escapeHtml(item.category)}</strong><span>${formatDate(item.date)} · ${item.type === "income" ? "Income keluarga" : sourceLabel(item.source)}</span></div>
      <b class="${item.type === "income" ? "positive" : "negative"}">${item.type === "income" ? "+" : "−"}${formatCompactRupiah(item.amount)}</b>
    </div>
  `;
}

function emptyStateHtml(icon, title, copy, action) {
  return `
    <div class="empty-state">
      <div class="empty-icon">${icon}</div>
      <h4>${title}</h4>
      <p>${copy}</p>
      <button class="button secondary" data-empty-action="${action}" type="button">＋ ${action === "asset" ? "Tambah aset" : "Tambah income"}</button>
    </div>
  `;
}

function bindDynamicActions() {
  $$("[data-empty-action]").forEach((button) => {
    button.addEventListener("click", () => {
      if (button.dataset.emptyAction === "asset") openAssetDialog();
      else openTransactionDialog("income");
    });
  });
}

function openTransactionDialog(mode) {
  state.transactionMode = mode;
  $("#transactionForm").reset();
  $("#transactionDate").value = today;
  $("#transactionDialogTitle").textContent = mode === "income" ? "Catat income" : "Catat outcome";
  $("#transactionDialogCopy").textContent = mode === "income"
    ? "Bagi pemasukan untuk suami, istri, dan tabungan."
    : "Catat pengeluaran dan pilih sumber dananya.";
  $("#incomeAllocation").classList.toggle("hidden", mode !== "income");
  $("#outcomeSourceGroup").classList.toggle("hidden", mode !== "outcome");

  const categories = mode === "income" ? incomeCategories : outcomeCategories;
  $("#transactionCategory").innerHTML = `<option value="">Pilih kategori</option>${categories.map((item) => `<option>${item}</option>`).join("")}`;
  updateAllocationStatus();
  $("#transactionDialog").showModal();
}

async function saveTransaction(event) {
  event.preventDefault();
  const amount = parseNumber($("#transactionAmount").value);
  const husband = parseNumber($("#husbandAllocation").value);
  const wife = parseNumber($("#wifeAllocation").value);
  const savings = parseNumber($("#savingsAllocation").value);

  if (amount <= 0) {
    showToast("Nominal harus lebih dari nol.", "error");
    return;
  }
  if (state.transactionMode === "income" && husband + wife + savings !== amount) {
    showToast("Total pembagian harus sama dengan nominal income.", "error");
    return;
  }

  const button = $("#saveTransactionButton");
  setButtonBusy(button, true, "Menyimpan…");
  const payload = {
    household_id: state.household.id,
    user_id: state.user.id,
    type: state.transactionMode,
    amount,
    date: $("#transactionDate").value,
    category: $("#transactionCategory").value,
    description: $("#transactionDescription").value.trim(),
    source: state.transactionMode === "outcome" ? $("#outcomeSource").value : null,
    husband_allocation: state.transactionMode === "income" ? husband : 0,
    wife_allocation: state.transactionMode === "income" ? wife : 0,
    savings_allocation: state.transactionMode === "income" ? savings : 0,
  };

  const { error } = await supabase.from("transactions").insert(payload);
  if (error) {
    showToast(error.message, "error");
  } else {
    $("#transactionDialog").close();
    showToast(state.transactionMode === "income" ? "Income berhasil dibagikan dan disimpan." : "Outcome berhasil disimpan.");
    await loadFinanceData();
  }
  setButtonBusy(button, false);
}

function updateAllocationStatus() {
  const amount = parseNumber($("#transactionAmount").value);
  const allocated = parseNumber($("#husbandAllocation").value) + parseNumber($("#wifeAllocation").value) + parseNumber($("#savingsAllocation").value);
  const remaining = amount - allocated;
  const status = $("#allocationRemaining");
  status.textContent = remaining === 0 ? "Pas" : `Sisa ${formatRupiah(remaining)}`;
  status.classList.toggle("balanced", remaining === 0);
  $("#saveTransactionButton").disabled = state.transactionMode === "income" && remaining !== 0;
}

function openAssetDialog() {
  $("#assetForm").reset();
  $("#assetQuantity").value = "1";
  $("#assetDialog").showModal();
}

async function saveAsset(event) {
  event.preventDefault();
  const button = $("#saveAssetButton");
  const currentValue = parseNumber($("#assetCurrentValue").value);

  if (currentValue < 0) {
    showToast("Nilai aset tidak valid.", "error");
    return;
  }

  setButtonBusy(button, true, "Menyimpan…");
  const payload = {
    household_id: state.household.id,
    user_id: state.user.id,
    asset_type: $("#assetType").value,
    name: $("#assetName").value.trim(),
    quantity: Number($("#assetQuantity").value),
    unit: $("#assetUnit").value,
    purchase_value: parseNumber($("#assetPurchaseValue").value),
    current_value: currentValue,
    notes: $("#assetNotes").value.trim(),
  };

  const { error } = await supabase.from("assets").insert(payload);
  if (error) {
    showToast(error.message, "error");
  } else {
    $("#assetDialog").close();
    showToast("Aset berhasil ditambahkan.");
    await loadFinanceData();
  }
  setButtonBusy(button, false);
}

async function deleteTransaction(id) {
  if (!confirm("Hapus transaksi ini? Saldo akan dihitung ulang.")) return;
  const { error } = await supabase
    .from("transactions")
    .delete()
    .eq("id", id)
    .eq("household_id", state.household.id);
  if (error) showToast(error.message, "error");
  else {
    showToast("Transaksi berhasil dihapus.");
    await loadFinanceData();
  }
}

async function deleteAsset(id) {
  if (!confirm("Hapus aset ini dari catatan?")) return;
  const { error } = await supabase
    .from("assets")
    .delete()
    .eq("id", id)
    .eq("household_id", state.household.id);
  if (error) showToast(error.message, "error");
  else {
    showToast("Aset berhasil dihapus.");
    await loadFinanceData();
  }
}

function setBusy(isBusy) {
  $("#loadingState").classList.toggle("hidden", !isBusy || !state.household);
  if (state.household) {
    $$(".view").forEach((view) => {
      if (isBusy) view.classList.add("hidden");
    });
    if (!isBusy) switchView(state.activeView);
  }
}

function setButtonBusy(button, busy, busyText = "Memproses…") {
  if (!button) return;
  if (busy) {
    button.dataset.originalText = button.textContent;
    button.textContent = busyText;
    button.disabled = true;
  } else {
    button.textContent = button.dataset.originalText || button.textContent;
    button.disabled = false;
  }
}

function showToast(message, type = "success") {
  const toast = document.createElement("div");
  toast.className = `toast ${type === "error" ? "error" : ""}`;
  toast.textContent = message;
  $("#toastContainer").append(toast);
  setTimeout(() => toast.remove(), 4200);
}

function parseNumber(value) {
  const number = Number(String(value ?? "").replace(/\D/g, ""));
  return Number.isFinite(number) ? number : 0;
}

function formatNumberInput(value) {
  const number = parseNumber(value);
  return number ? new Intl.NumberFormat("id-ID").format(number) : "";
}

function formatRupiah(value) {
  return new Intl.NumberFormat("id-ID", {
    style: "currency",
    currency: "IDR",
    maximumFractionDigits: 0,
  }).format(Number(value) || 0);
}

function formatCompactRupiah(value) {
  return new Intl.NumberFormat("id-ID", {
    style: "currency",
    currency: "IDR",
    notation: "compact",
    maximumFractionDigits: 1,
  }).format(Number(value) || 0);
}

function formatDate(date, includeYear = false) {
  return new Date(`${date}T00:00:00`).toLocaleDateString("id-ID", {
    day: "numeric",
    month: "short",
    ...(includeYear ? { year: "numeric" } : {}),
  });
}

function formatQuantity(value) {
  return new Intl.NumberFormat("id-ID", { maximumFractionDigits: 2 }).format(Number(value));
}

function sourceLabel(source) {
  if (source === "husband") return "Uang suami";
  if (source === "wife") return "Uang istri";
  return "Tabungan";
}

function assetSymbol(type) {
  if (type === "Emas") return "Au";
  return String(type || "As").slice(0, 2);
}

function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

function translateAuthError(message) {
  const lower = message.toLowerCase();
  if (lower.includes("invalid login credentials")) return "Email atau password salah.";
  if (lower.includes("email not confirmed")) return "Email belum dikonfirmasi. Periksa kotak masukmu.";
  if (lower.includes("already registered")) return "Email sudah terdaftar.";
  if (lower.includes("password")) return "Password minimal 6 karakter.";
  return message;
}
