import { createClient } from "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm";
import { SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY } from "./config.js";

const $ = (selector) => document.querySelector(selector);
const $$ = (selector) => [...document.querySelectorAll(selector)];
const currentDate = new Date();
const currentMonthKey = `${currentDate.getFullYear()}-${String(currentDate.getMonth() + 1).padStart(2, "0")}`;

const state = {
  user: null,
  household: null,
  householdMembers: [],
  transactions: [],
  assets: [],
  transfers: [],
  adjustments: [],
  auditLogs: [],
  monthlyBills: [],
  monthlyBillPayments: [],
  savingsAccounts: [],
  authMode: "login",
  transactionMode: "income",
  transactionFilter: "all",
  transactionMemberFilter: "all",
  transactionMonth: currentMonthKey,
  logsMonth: currentMonthKey,
  adjustmentOperator: "add",
  editingTransactionId: null,
  editingAssetId: null,
  editingMonthlyBillId: null,
  activeMonthlyBillMemberId: null,
  editingMemberRoleId: null,
  removingMemberId: null,
  editingSavingsAccountId: null,
  archivingSavingsAccountId: null,
  activeView: "dashboard",
  lockedScrollY: 0,
};

const incomeCategories = ["Gaji", "Bonus", "Usaha", "Investasi", "Hadiah", "Lainnya"];
const outcomeCategories = ["Makan & minum", "Tagihan", "Transportasi", "Kesehatan", "Kecantikan", "Belanja", "Hiburan", "Rumah tangga", "Lainnya"];
const chartColors = ["#bd5a58", "#d6a84d", "#3f806b", "#728e60", "#b97891", "#8069a8", "#d07c4f", "#68889c", "#8a918c"];
const today = new Date().toISOString().slice(0, 10);
const authUsernameDomain = "users.keuangan-kita.invalid";
const usernamePattern = /^[a-z0-9](?:[a-z0-9._-]{1,28}[a-z0-9])?$/;

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
        openModal($("#passwordDialog"));
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
    state.householdMembers = [];
    state.transactions = [];
    state.assets = [];
    state.transfers = [];
    state.adjustments = [];
    state.auditLogs = [];
    state.monthlyBills = [];
    state.monthlyBillPayments = [];
    state.savingsAccounts = [];
    state.transactionMonth = currentMonthKey;
    state.logsMonth = currentMonthKey;
    showScreen("auth");
    setBusy(false);
    return;
  }

  await loadHousehold();
}

async function loadHousehold() {
  const { data, error } = await supabase
    .from("household_members")
    .select("household_id, role, display_name, households!inner(id, name, invite_code, created_by, payday_enabled, payday_day)")
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
    display_name: data.display_name,
  };

  showScreen("app");
  fillProfile();
  await loadFinanceData();
}

async function loadFinanceData() {
  setBusy(true);
  const householdId = state.household.id;
  const [transactionsResult, assetsResult, membersResult, transfersResult, adjustmentsResult, logsResult, billsResult, billPaymentsResult, savingsResult] = await Promise.all([
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
    supabase
      .from("household_member_profiles")
      .select("user_id, system_role, family_role, display_name, email, color_index, is_active, joined_at, removed_at")
      .eq("household_id", householdId),
    supabase
      .from("balance_transfers")
      .select("*")
      .eq("household_id", householdId)
      .order("date", { ascending: false })
      .order("created_at", { ascending: false }),
    supabase
      .from("balance_adjustments")
      .select("*")
      .eq("household_id", householdId)
      .order("created_at", { ascending: false }),
    supabase
      .from("audit_logs")
      .select("*")
      .eq("household_id", householdId)
      .order("created_at", { ascending: false }),
    supabase
      .from("monthly_bills")
      .select("*")
      .eq("household_id", householdId)
      .order("balance_key", { ascending: true })
      .order("subscription_day", { ascending: true })
      .order("created_at", { ascending: true }),
    supabase
      .from("monthly_bill_payments")
      .select("*")
      .eq("household_id", householdId)
      .eq("billing_month", currentBillingMonthKey()),
    supabase
      .from("savings_accounts")
      .select("*")
      .eq("household_id", householdId)
      .order("sort_order", { ascending: true })
      .order("created_at", { ascending: true }),
  ]);

  const loadError = transactionsResult.error
    || assetsResult.error
    || membersResult.error
    || transfersResult.error
    || adjustmentsResult.error
    || logsResult.error
    || billsResult.error
    || billPaymentsResult.error
    || savingsResult.error;
  if (loadError) {
    showToast(loadError.message || "Data gagal dimuat.", "error");
  } else {
    state.transactions = transactionsResult.data ?? [];
    state.assets = assetsResult.data ?? [];
    state.householdMembers = membersResult.data ?? [];
    state.transfers = transfersResult.data ?? [];
    state.adjustments = adjustmentsResult.data ?? [];
    state.auditLogs = logsResult.data ?? [];
    state.monthlyBills = billsResult.data ?? [];
    state.monthlyBillPayments = billPaymentsResult.data ?? [];
    state.savingsAccounts = savingsResult.data ?? [];
    fillProfile();
    renderAll();
  }
  setBusy(false);
}

function bindEvents() {
  $("#loginTab").addEventListener("click", () => setAuthMode("login"));
  $("#registerTab").addEventListener("click", () => setAuthMode("register"));
  $("#authForm").addEventListener("submit", submitAuth);
  $("#createHouseholdForm").addEventListener("submit", createHousehold);
  $("#joinHouseholdForm").addEventListener("submit", joinHousehold);
  $("#onboardingLogout").addEventListener("click", logout);
  $("#logoutButton").addEventListener("click", logout);
  $("#editUserNameButton").addEventListener("click", openUserNameDialog);
  $("#editHouseholdNameButton").addEventListener("click", openHouseholdNameDialog);
  $("#manageMembersButton").addEventListener("click", openMembersDialog);
  $("#copyInviteCode").addEventListener("click", copyInviteCode);

  $$(".nav-button").forEach((button) => {
    button.addEventListener("click", () => switchView(button.dataset.view));
  });

  $("#topIncomeButton").addEventListener("click", () => openTransactionDialog("income"));
  $("#topOutcomeButton").addEventListener("click", () => openTransactionDialog("outcome"));
  $("#topTransferButton").addEventListener("click", openTransferDialog);
  $("#adjustBalanceButton").addEventListener("click", openAdjustmentDialog);
  $("#manageSavingsButton").addEventListener("click", openSavingsDialog);
  $("#paydaySettingsButton").addEventListener("click", openPaydaySettingsDialog);
  $("#viewIncomeButton").addEventListener("click", () => openTransactionDialog("income"));
  $("#viewOutcomeButton").addEventListener("click", () => openTransactionDialog("outcome"));
  $("#addAssetButton").addEventListener("click", () => openAssetDialog());

  $("#transactionDialog .modal-close").addEventListener("click", () => $("#transactionDialog").close());
  $("#assetDialog .modal-close").addEventListener("click", () => $("#assetDialog").close());
  $("#userNameDialog .modal-close").addEventListener("click", () => $("#userNameDialog").close());
  $("#householdNameDialog .modal-close").addEventListener("click", () => $("#householdNameDialog").close());
  $("#paydaySettingsDialog .modal-close").addEventListener("click", () => $("#paydaySettingsDialog").close());
  $("#savingsDialog .modal-close").addEventListener("click", () => $("#savingsDialog").close());
  $("#savingsAccountFormDialog .modal-close").addEventListener("click", () => $("#savingsAccountFormDialog").close());
  $("#archiveSavingsDialog .modal-close").addEventListener("click", () => $("#archiveSavingsDialog").close());
  $("#transactionDetailDialog .modal-close").addEventListener("click", () => $("#transactionDetailDialog").close());
  $("#transactionDetailDialog").addEventListener("click", closeTransactionDetailFromBackdrop);
  $("#transferDialog .modal-close").addEventListener("click", () => $("#transferDialog").close());
  $("#adjustmentDialog .modal-close").addEventListener("click", () => $("#adjustmentDialog").close());
  $("#monthlyBillsDialog .modal-close").addEventListener("click", () => $("#monthlyBillsDialog").close());
  $("#monthlyBillsDialog").addEventListener("click", closeMonthlyBillsFromBackdrop);
  $("#monthlyBillFormDialog .modal-close").addEventListener("click", closeMonthlyBillForm);
  $("#membersDialog .modal-close").addEventListener("click", () => $("#membersDialog").close());
  $("#memberRoleDialog .modal-close").addEventListener("click", () => $("#memberRoleDialog").close());
  $("#removeMemberDialog .modal-close").addEventListener("click", () => $("#removeMemberDialog").close());
  $("#transactionForm").addEventListener("submit", saveTransaction);
  $("#assetForm").addEventListener("submit", saveAsset);
  $("#passwordForm").addEventListener("submit", saveNewPassword);
  $("#userNameForm").addEventListener("submit", saveUserName);
  $("#householdNameForm").addEventListener("submit", saveHouseholdName);
  $("#paydaySettingsForm").addEventListener("submit", savePaydaySettings);
  $("#savingsAccountForm").addEventListener("submit", saveSavingsAccount);
  $("#archiveSavingsForm").addEventListener("submit", archiveSavingsAccount);
  $("#transferForm").addEventListener("submit", saveTransfer);
  $("#adjustmentForm").addEventListener("submit", saveAdjustment);
  $("#monthlyBillForm").addEventListener("submit", saveMonthlyBill);
  $("#memberRoleForm").addEventListener("submit", saveMemberRole);
  $("#removeMemberForm").addEventListener("submit", removeMember);
  $("#addMonthlyBillButton").addEventListener("click", () => openMonthlyBillForm());
  $("#addSavingsAccountButton").addEventListener("click", () => openSavingsAccountForm());
  $$(".modal").forEach((dialog) => dialog.addEventListener("close", unlockPageScroll));

  $$(".filter-tabs button").forEach((button) => {
    button.addEventListener("click", () => {
      state.transactionFilter = button.dataset.filter;
      $$(".filter-tabs button").forEach((item) => item.classList.toggle("active", item === button));
      renderTransactions();
      renderHistoryChart();
    });
  });

  $("#transactionMonthFilter").addEventListener("change", (event) => {
    state.transactionMonth = event.target.value;
    renderTransactions();
    renderHistoryChart();
  });
  $("#logsMonthFilter").addEventListener("change", (event) => {
    state.logsMonth = event.target.value;
    renderLogs();
  });

  [
    "#transactionAmount",
    "#assetPurchaseValue",
    "#assetCurrentValue",
    "#transferAmount",
    "#adjustmentNewBalance",
    "#adjustmentDelta",
    "#monthlyBillAmount",
  ].forEach((selector) => {
    $(selector)?.addEventListener("input", (event) => {
      const keepZero = selector === "#adjustmentNewBalance" || selector === "#adjustmentDelta";
      event.target.value = selector === "#adjustmentNewBalance"
        ? formatSignedNumberInput(event.target.value)
        : keepZero ? formatNumberInputIncludingZero(event.target.value)
        : formatNumberInput(event.target.value);
      if (selector.includes("Allocation") || selector === "#transactionAmount") updateAllocationStatus();
      if (selector.startsWith("#asset")) updateAssetCalculation();
    });
  });

  $("#assetQuantity").addEventListener("input", updateAssetCalculation);
  $("#assetUnit").addEventListener("change", updateAssetCalculation);
  $("#transferSource").addEventListener("change", updateTransferFields);
  $("#adjustmentBalance").addEventListener("change", updateAdjustmentFields);
  $("#adjustmentNewBalance").addEventListener("input", syncAdjustmentFromNewBalance);
  $("#adjustmentDelta").addEventListener("input", syncAdjustmentFromDelta);
  $$('[data-adjustment-operator]').forEach((button) => {
    button.addEventListener("click", () => setAdjustmentOperator(button.dataset.adjustmentOperator));
  });

  $("#inviteCodeInput").addEventListener("input", (event) => {
    event.target.value = event.target.value.toUpperCase().replace(/[^A-Z0-9]/g, "");
  });
  $("#memberAllocationFields").addEventListener("input", (event) => {
    if (!event.target.matches("[data-member-allocation]")) return;
    event.target.value = formatNumberInput(event.target.value);
    updateAllocationStatus();
  });
  $("#savingsAllocationFields").addEventListener("input", (event) => {
    if (!event.target.matches("[data-savings-allocation]")) return;
    event.target.value = formatNumberInput(event.target.value);
    updateAllocationStatus();
  });
  $("#memberRolePreset").addEventListener("change", toggleCustomRoleField);
  $("#removeMemberConfirmation").addEventListener("input", updateRemoveMemberButton);
  $("#archiveSavingsConfirmation").addEventListener("input", updateArchiveSavingsButton);
  $("#paydayEnabled").addEventListener("change", updatePaydaySettingsFields);
}

function setAuthMode(mode) {
  state.authMode = mode;
  $("#loginTab").classList.toggle("active", mode === "login");
  $("#registerTab").classList.toggle("active", mode === "register");
  $("#authSubmit").textContent = mode === "login" ? "Masuk" : "Buat akun";
  $("#authIdentifierLabel").textContent = mode === "login" ? "Username atau email" : "Username";
  $("#authIdentifier").placeholder = mode === "login" ? "Masukkan username" : "Contoh: alyuza";
  $("#authIdentifier").maxLength = mode === "login" ? 320 : 30;
  $("#authIdentifierHint").textContent = mode === "login"
    ? "Email lama tetap dapat dipakai selama proses migrasi."
    : "Gunakan 3–30 huruf kecil, angka, titik, garis bawah, atau tanda hubung.";
  $("#authPassword").autocomplete = mode === "login" ? "current-password" : "new-password";
}

async function submitAuth(event) {
  event.preventDefault();
  if (!supabase) return;

  const identifier = $("#authIdentifier").value.trim().toLowerCase();
  const password = $("#authPassword").value;
  const username = identifier.includes("@") ? "" : normalizeUsername(identifier);

  if (state.authMode === "register" && !isValidUsername(username)) {
    showToast("Username harus 3–30 karakter, diawali dan diakhiri huruf/angka.", "error");
    $("#authIdentifier").focus();
    return;
  }

  const email = identifier.includes("@") ? identifier : usernameToAuthEmail(username);
  setButtonBusy($("#authSubmit"), true, state.authMode === "login" ? "Memproses…" : "Membuat akun…");

  if (state.authMode === "login") {
    const { error } = await supabase.auth.signInWithPassword({ email, password });
    if (error) showToast(translateAuthError(error.message), "error");
  } else {
    const { data, error } = await supabase.auth.signUp({
      email,
      password,
      options: { data: { username } },
    });
    if (error) {
      showToast(translateAuthError(error.message), "error");
    } else if (!data.session) {
      const duplicateUsername = Array.isArray(data.user?.identities) && data.user.identities.length === 0;
      showToast(
        duplicateUsername
          ? "Username sudah digunakan."
          : "Akun dibuat, tetapi login langsung belum aktif. Nonaktifkan Confirm Email di Supabase lalu konfirmasi akun ini dari admin.",
        "error",
      );
    } else {
      showToast("Akun berhasil dibuat dan langsung masuk.");
    }
  }

  setButtonBusy($("#authSubmit"), false);
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
    showToast("Akun berhasil bergabung ke ruang keluarga.");
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
  const username = usernameFromEmail(email);
  const fallbackName = username || "Pengguna";
  const currentMember = state.householdMembers.find((member) => member.user_id === state.user.id);
  const name = currentMember?.display_name || state.household.display_name || fallbackName;
  $("#userName").textContent = name;
  $("#userRole").textContent = currentMember?.family_role || "None";
  $("#userUsername").textContent = username ? `@${username}` : "";
  $("#userAvatar").textContent = name.slice(0, 1).toUpperCase();
  $("#sidebarHousehold").textContent = state.household.name;
  $("#mobileHouseholdName").textContent = state.household.name;
  $("#sidebarInviteCode").textContent = state.household.invite_code;
  $("#manageMembersButton").classList.toggle("hidden", !isRoomMaster());
  $("#editHouseholdNameButton").classList.toggle("hidden", !isRoomMaster());
  $("#manageSavingsButton").classList.toggle("hidden", !isRoomMaster());
  $("#paydaySettingsButton").classList.toggle("hidden", !isRoomMaster());
}

function isRoomMaster() {
  return state.household?.created_by === state.user?.id || state.household?.role === "owner";
}

function activeHouseholdMembers() {
  return state.householdMembers
    .filter((member) => member.is_active)
    .sort((a, b) => String(a.joined_at).localeCompare(String(b.joined_at)));
}

function memberById(userId) {
  return state.householdMembers.find((member) => String(member.user_id) === String(userId)) ?? null;
}

function memberRoleLabel(member) {
  return member?.family_role?.trim() || "None";
}

function memberBalanceKey(userId) {
  return `member:${userId}`;
}

function savingsBalanceKey(accountId) {
  return `saving:${accountId}`;
}

function activeSavingsAccounts() {
  return state.savingsAccounts.filter((account) => !account.is_archived);
}

function savingsAccountById(accountId) {
  return state.savingsAccounts.find((account) => String(account.id) === String(accountId)) ?? null;
}

function savingsAccountByLegacyKey(legacyKey) {
  return state.savingsAccounts.find((account) => account.legacy_key === legacyKey) ?? null;
}

function memberColorClass(member) {
  return `member-color-${Number(member?.color_index || 0) % 8}`;
}

function memberBalanceLabel(member) {
  const role = memberRoleLabel(member);
  return role === "None" ? `Uang ${member?.display_name || "anggota"}` : `Uang ${role}`;
}

function canManageTransaction(transaction) {
  return isRoomMaster() || String(transaction?.user_id) === String(state.user?.id);
}

function openUserNameDialog() {
  const email = state.user.email ?? "";
  const fallbackName = usernameFromEmail(email) || "Pengguna";
  const currentMember = state.householdMembers.find((member) => member.user_id === state.user.id);
  $("#userNameInput").value = currentMember?.display_name || state.household.display_name || fallbackName;
  openModal($("#userNameDialog"));
  setTimeout(() => $("#userNameInput").focus(), 0);
}

async function saveUserName(event) {
  event.preventDefault();
  const displayName = $("#userNameInput").value.trim();
  if (!displayName) {
    showToast("Nama pengguna tidak boleh kosong.", "error");
    return;
  }

  const button = $("#saveUserNameButton");
  setButtonBusy(button, true, "Menyimpan…");
  const { error } = await supabase.rpc("update_own_display_name", { new_display_name: displayName });

  if (error) {
    showToast(error.message, "error");
  } else {
    state.household.display_name = displayName;
    $("#userNameDialog").close();
    await loadFinanceData();
    fillProfile();
    showToast("Nama pengguna berhasil diperbarui.");
  }
  setButtonBusy(button, false);
}

function openHouseholdNameDialog() {
  if (!isRoomMaster()) return;
  $("#householdNameInput").value = state.household.name || "";
  openModal($("#householdNameDialog"));
  setTimeout(() => $("#householdNameInput").focus(), 0);
}

async function saveHouseholdName(event) {
  event.preventDefault();
  if (!isRoomMaster()) return;
  const name = $("#householdNameInput").value.trim();
  if (!name || name.length > 50) {
    showToast("Nama keluarga harus terdiri dari 1–50 karakter.", "error");
    return;
  }
  const button = $("#saveHouseholdNameButton");
  setButtonBusy(button, true, "Menyimpan…");
  const { error } = await supabase.rpc("update_household_name", { new_name: name });
  if (error) {
    showToast(error.message, "error");
  } else {
    state.household.name = name;
    $("#householdNameDialog").close();
    fillProfile();
    showToast("Nama keluarga berhasil diperbarui.");
  }
  setButtonBusy(button, false);
}

function openPaydaySettingsDialog() {
  if (!isRoomMaster()) return;
  $("#paydayEnabled").checked = state.household.payday_enabled !== false;
  $("#paydayDay").value = Number(state.household.payday_day || 10);
  updatePaydaySettingsFields();
  openModal($("#paydaySettingsDialog"));
}

function updatePaydaySettingsFields() {
  const enabled = $("#paydayEnabled").checked;
  $("#paydayDayGroup").classList.toggle("disabled-field", !enabled);
  $("#paydayDay").disabled = !enabled;
  $("#paydayDay").required = enabled;
}

async function savePaydaySettings(event) {
  event.preventDefault();
  if (!isRoomMaster()) return;
  const enabled = $("#paydayEnabled").checked;
  const day = enabled ? Number($("#paydayDay").value) : Number(state.household.payday_day || 10);
  if (enabled && (!Number.isInteger(day) || day < 1 || day > 31)) {
    showToast("Tanggal gajian harus antara 1–31.", "error");
    return;
  }
  const button = $("#savePaydaySettingsButton");
  setButtonBusy(button, true, "Menyimpan…");
  const { error } = await supabase.rpc("update_household_payday", { enabled, salary_day: day });
  if (error) {
    showToast(error.message, "error");
  } else {
    state.household.payday_enabled = enabled;
    state.household.payday_day = day;
    $("#paydaySettingsDialog").close();
    renderDashboard();
    showToast(enabled ? `Tanggal gajian diatur setiap tanggal ${day}.` : "Tanggal gajian dinonaktifkan. Rekomendasi mengikuti awal bulan.");
  }
  setButtonBusy(button, false);
}

function openSavingsDialog() {
  if (!isRoomMaster()) return;
  renderSavingsAccountList();
  openModal($("#savingsDialog"));
}

function renderSavingsAccountList() {
  const totals = getTotals();
  const accounts = activeSavingsAccounts();
  $("#savingsAccountList").innerHTML = accounts.length ? accounts.map((account) => {
    const balance = Number(totals.savingsAccountBalances[String(account.id)] || 0);
    return `
      <article class="member-management-row savings-account-row">
        <div class="member-management-avatar member-color-${Number(account.sort_order || 0) % 8}">◇</div>
        <div class="member-management-info">
          <div><strong>${escapeHtml(account.name)}</strong>${account.include_in_net_worth ? "<b>Masuk total</b>" : "<b>Di luar total</b>"}</div>
          <small>Saldo ${formatRupiah(balance)}</small>
        </div>
        <div class="member-management-actions">
          <button data-edit-savings="${account.id}" type="button">✎ Edit</button>
          <button class="remove" data-archive-savings="${account.id}" type="button">Hapus</button>
        </div>
      </article>`;
  }).join("") : `<div class="empty-state compact"><h4>Belum ada tabungan aktif</h4><p>Tambahkan pos untuk mulai membagi saldo.</p></div>`;
  $$('[data-edit-savings]').forEach((button) => button.addEventListener("click", () => openSavingsAccountForm(button.dataset.editSavings)));
  $$('[data-archive-savings]').forEach((button) => button.addEventListener("click", () => openArchiveSavingsDialog(button.dataset.archiveSavings)));
}

function openSavingsAccountForm(accountId = null) {
  if (!isRoomMaster()) return;
  const account = accountId ? savingsAccountById(accountId) : null;
  state.editingSavingsAccountId = account?.id || null;
  $("#savingsAccountForm").reset();
  $("#savingsAccountFormTitle").textContent = account ? "Edit tabungan" : "Tambah tabungan";
  $("#savingsAccountName").value = account?.name || "";
  $("#savingsIncludeNetWorth").checked = account ? Boolean(account.include_in_net_worth) : true;
  openModal($("#savingsAccountFormDialog"));
  setTimeout(() => $("#savingsAccountName").focus(), 0);
}

async function saveSavingsAccount(event) {
  event.preventDefault();
  if (!isRoomMaster()) return;
  const name = $("#savingsAccountName").value.trim();
  if (!name || name.length > 40) {
    showToast("Nama tabungan harus terdiri dari 1–40 karakter.", "error");
    return;
  }
  const button = $("#saveSavingsAccountButton");
  setButtonBusy(button, true, "Menyimpan…");
  const { error } = await supabase.rpc("save_savings_account", {
    p_account_id: state.editingSavingsAccountId,
    p_name: name,
    p_include_in_net_worth: $("#savingsIncludeNetWorth").checked,
  });
  if (error) {
    showToast(error.message, "error");
  } else {
    $("#savingsAccountFormDialog").close();
    showToast(state.editingSavingsAccountId ? "Tabungan berhasil diperbarui." : "Tabungan berhasil ditambahkan.");
    state.editingSavingsAccountId = null;
    await loadFinanceData();
    if ($("#savingsDialog").open) renderSavingsAccountList();
  }
  setButtonBusy(button, false);
}

function openArchiveSavingsDialog(accountId) {
  if (!isRoomMaster()) return;
  const account = savingsAccountById(accountId);
  if (!account || account.is_archived) return;
  state.archivingSavingsAccountId = account.id;
  const balance = Number(getTotals().savingsAccountBalances[String(account.id)] || 0);
  $("#archiveSavingsConfirmation").value = "";
  $("#archiveSavingsCopy").textContent = `${account.name} akan disembunyikan dari dashboard dan form baru. Riwayat lama tetap tersimpan.`;
  $("#archiveSavingsBalance").innerHTML = `<span>Saldo saat ini</span><strong>${formatRupiah(balance)}</strong>`;
  $("#archiveSavingsBalance").dataset.canArchive = String(balance === 0);
  updateArchiveSavingsButton();
  openModal($("#archiveSavingsDialog"));
}

function updateArchiveSavingsButton() {
  const confirmed = $("#archiveSavingsConfirmation").value.trim().toUpperCase() === "HAPUS";
  const zeroBalance = $("#archiveSavingsBalance").dataset.canArchive === "true";
  $("#confirmArchiveSavingsButton").disabled = !(confirmed && zeroBalance);
  $("#archiveSavingsBalance").classList.toggle("warning", !zeroBalance);
}

async function archiveSavingsAccount(event) {
  event.preventDefault();
  const confirmation = $("#archiveSavingsConfirmation").value.trim().toUpperCase();
  if (!isRoomMaster() || confirmation !== "HAPUS" || $("#archiveSavingsBalance").dataset.canArchive !== "true") return;
  const button = $("#confirmArchiveSavingsButton");
  setButtonBusy(button, true, "Mengarsipkan…");
  const { error } = await supabase.rpc("archive_savings_account", {
    p_account_id: state.archivingSavingsAccountId,
    confirmation_text: confirmation,
  });
  if (error) {
    showToast(error.message, "error");
  } else {
    $("#archiveSavingsDialog").close();
    showToast("Tabungan berhasil diarsipkan. Riwayat lama tetap aman.");
    state.archivingSavingsAccountId = null;
    await loadFinanceData();
    if ($("#savingsDialog").open) renderSavingsAccountList();
  }
  setButtonBusy(button, false);
}

function openMembersDialog() {
  if (!isRoomMaster()) return;
  renderMembersList();
  openModal($("#membersDialog"));
}

function renderMembersList() {
  const totals = getTotals();
  $("#membersList").innerHTML = activeHouseholdMembers().map((member) => {
    const isMaster = member.system_role === "owner" || String(state.household.created_by) === String(member.user_id);
    const balance = Number(totals.memberBalances[String(member.user_id)] || 0);
    return `
      <article class="member-management-row">
        <div class="member-management-avatar ${memberColorClass(member)}">${escapeHtml(member.display_name.slice(0, 1).toUpperCase())}</div>
        <div class="member-management-info">
          <div><strong>${escapeHtml(member.display_name)}</strong>${isMaster ? "<b>Room master</b>" : ""}</div>
          <span>@${escapeHtml(usernameFromEmail(member.email))}</span>
          <small>${escapeHtml(memberRoleLabel(member))} · Saldo ${formatRupiah(balance)}</small>
        </div>
        <div class="member-management-actions">
          <button data-edit-member-role="${member.user_id}" type="button" aria-label="Ubah role ${escapeHtml(member.display_name)}">✎ Role</button>
          ${String(member.user_id) !== String(state.user.id) ? `<button class="remove" data-remove-member="${member.user_id}" type="button" aria-label="Hapus akses ${escapeHtml(member.display_name)}">Hapus</button>` : ""}
        </div>
      </article>`;
  }).join("");

  $$('[data-edit-member-role]').forEach((button) => button.addEventListener("click", () => openMemberRoleDialog(button.dataset.editMemberRole)));
  $$('[data-remove-member]').forEach((button) => button.addEventListener("click", () => openRemoveMemberDialog(button.dataset.removeMember)));
}

function openMemberRoleDialog(userId) {
  if (!isRoomMaster()) return;
  const member = memberById(userId);
  if (!member?.is_active) return;
  state.editingMemberRoleId = userId;
  const presets = ["None", "Suami", "Istri", "Anak"];
  const currentRole = memberRoleLabel(member);
  $("#memberRoleCopy").textContent = `Role ini akan tampil untuk ${member.display_name} pada profil dan riwayat.`;
  $("#memberRolePreset").value = presets.includes(currentRole) ? currentRole : "custom";
  $("#memberCustomRole").value = presets.includes(currentRole) ? "" : currentRole;
  toggleCustomRoleField();
  openModal($("#memberRoleDialog"));
}

function toggleCustomRoleField() {
  const custom = $("#memberRolePreset").value === "custom";
  $("#memberCustomRoleGroup").classList.toggle("hidden", !custom);
  $("#memberCustomRole").required = custom;
}

async function saveMemberRole(event) {
  event.preventDefault();
  const preset = $("#memberRolePreset").value;
  const role = (preset === "custom" ? $("#memberCustomRole").value : preset).trim();
  if (!role || role.length > 30) {
    showToast("Role harus terdiri dari 1–30 karakter.", "error");
    return;
  }
  const button = $("#saveMemberRoleButton");
  setButtonBusy(button, true, "Menyimpan…");
  const { error } = await supabase.rpc("set_member_family_role", {
    target_user_id: state.editingMemberRoleId,
    new_family_role: role,
  });
  if (error) {
    showToast(error.message, "error");
  } else {
    $("#memberRoleDialog").close();
    showToast("Role keluarga berhasil diperbarui.");
    await loadFinanceData();
    if ($("#membersDialog").open) renderMembersList();
  }
  setButtonBusy(button, false);
}

function openRemoveMemberDialog(userId) {
  if (!isRoomMaster()) return;
  const member = memberById(userId);
  if (!member?.is_active || String(userId) === String(state.user.id)) return;
  state.removingMemberId = userId;
  $("#removeMemberConfirmation").value = "";
  const balance = Number(getTotals().memberBalances[String(userId)] || 0);
  $("#removeMemberCopy").textContent = `Akses ${member.display_name} akan dicabut, tetapi seluruh riwayatnya tetap tersimpan. Tindakan ini tidak menghapus akun login.`;
  $("#removeMemberBalance").innerHTML = `<span>Saldo ${escapeHtml(member.display_name)}</span><strong class="${balance < 0 ? "negative" : ""}">${formatRupiah(balance)}</strong>`;
  $("#removeMemberBalance").dataset.canRemove = String(balance === 0);
  updateRemoveMemberButton();
  openModal($("#removeMemberDialog"));
}

function updateRemoveMemberButton() {
  const confirmed = $("#removeMemberConfirmation").value.trim().toUpperCase() === "HAPUS";
  const zeroBalance = $("#removeMemberBalance").dataset.canRemove === "true";
  $("#confirmRemoveMemberButton").disabled = !(confirmed && zeroBalance);
  $("#removeMemberBalance").classList.toggle("warning", !zeroBalance);
}

async function removeMember(event) {
  event.preventDefault();
  const confirmation = $("#removeMemberConfirmation").value.trim().toUpperCase();
  if (confirmation !== "HAPUS" || $("#removeMemberBalance").dataset.canRemove !== "true") return;
  const button = $("#confirmRemoveMemberButton");
  setButtonBusy(button, true, "Menghapus akses…");
  const { error } = await supabase.rpc("remove_household_member", {
    target_user_id: state.removingMemberId,
    confirmation_text: confirmation,
  });
  if (error) {
    showToast(error.message, "error");
  } else {
    $("#removeMemberDialog").close();
    showToast("Akses anggota dihapus. Riwayat tetap tersimpan.");
    await loadFinanceData();
    if ($("#membersDialog").open) renderMembersList();
  }
  setButtonBusy(button, false);
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
    logs: ["JEJAK PERUBAHAN", "Logs aktivitas"],
  };

  $$(".view").forEach((item) => item.classList.add("hidden"));
  $(`#${view}View`).classList.remove("hidden");
  $$(".nav-button").forEach((button) => button.classList.toggle("active", button.dataset.view === view));
  $("#pageEyebrow").textContent = titles[view][0];
  $("#pageTitle").textContent = titles[view][1];
}

function renderAll() {
  renderDashboard();
  renderMemberFilters();
  renderTransactionMonthOptions();
  renderTransactions();
  renderHistoryChart();
  renderAssets();
  renderLogMonthOptions();
  renderLogs();
  switchView(state.activeView);
}

function renderMemberFilters() {
  const transactionUserIds = new Set(state.transactions.map((item) => String(item.user_id)).filter(Boolean));
  const members = state.householdMembers
    .filter((member) => member.is_active || transactionUserIds.has(String(member.user_id)))
    .sort((a, b) => String(a.joined_at).localeCompare(String(b.joined_at)));
  const validFilters = new Set(["all", ...members.map((member) => String(member.user_id))]);
  if (!validFilters.has(state.transactionMemberFilter)) state.transactionMemberFilter = "all";
  $("#memberFilterTabs").innerHTML = `
    <button class="${state.transactionMemberFilter === "all" ? "active" : ""}" data-member-filter="all" type="button">Semua</button>
    ${members.map((member) => `<button class="${state.transactionMemberFilter === String(member.user_id) ? "active" : ""}" data-member-filter="${member.user_id}" type="button">${escapeHtml(memberRoleLabel(member))}${member.is_active ? "" : " · Dihapus"}</button>`).join("")}`;

  $$("#memberFilterTabs button").forEach((button) => {
    button.addEventListener("click", () => {
      state.transactionMemberFilter = button.dataset.memberFilter;
      $$("#memberFilterTabs button").forEach((item) => item.classList.toggle("active", item === button));
      renderTransactions();
      renderHistoryChart();
    });
  });
}

function getTotals() {
  let income = 0;
  let outcome = 0;
  let monthIncome = 0;
  let monthOutcome = 0;
  const now = new Date();
  const monthKey = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, "0")}`;
  const memberBalances = Object.fromEntries(state.householdMembers.map((member) => [String(member.user_id), 0]));
  const savingsAccountBalances = Object.fromEntries(state.savingsAccounts.map((account) => [String(account.id), 0]));
  const legacyOwner = state.householdMembers
    .filter((member) => member.system_role === "owner")
    .sort((a, b) => String(a.joined_at).localeCompare(String(b.joined_at)))[0];
  const legacyMember = state.householdMembers
    .filter((member) => member.system_role === "member")
    .sort((a, b) => String(a.joined_at).localeCompare(String(b.joined_at)))[0];
  const addMemberBalance = (userId, amount) => {
    if (!userId) return;
    const key = String(userId);
    memberBalances[key] = Number(memberBalances[key] || 0) + Number(amount || 0);
  };
  const addSavingsBalance = (accountId, amount) => {
    if (!accountId) return;
    const key = String(accountId);
    savingsAccountBalances[key] = Number(savingsAccountBalances[key] || 0) + Number(amount || 0);
  };
  const transferMemberId = (item, side) => {
    const balance = item[`${side}_balance`];
    if (balance === "member") return item[`${side}_member_id`];
    if (balance === "husband") return legacyOwner?.user_id;
    if (balance === "wife") return legacyMember?.user_id;
    return null;
  };
  const transferSavingsId = (item, side) => {
    const balance = item[`${side}_balance`];
    if (balance === "savings_account") return item[`${side}_savings_account_id`];
    return savingsAccountByLegacyKey(balance)?.id || null;
  };

  state.transactions.forEach((item) => {
    const amount = Number(item.amount);
    if (item.type === "income") {
      income += amount;
      Object.entries(item.member_allocations || {}).forEach(([userId, allocation]) => addMemberBalance(userId, allocation));
      addMemberBalance(legacyOwner?.user_id, item.husband_allocation);
      addMemberBalance(legacyMember?.user_id, item.wife_allocation);
      Object.entries(transactionSavingsAllocations(item)).forEach(([accountId, allocation]) => addSavingsBalance(accountId, allocation));
      if (item.date.startsWith(monthKey)) monthIncome += amount;
    } else {
      outcome += amount;
      if (item.source === "member") addMemberBalance(item.source_member_id, -amount);
      if (item.source === "husband") addMemberBalance(legacyOwner?.user_id, -amount);
      if (item.source === "wife") addMemberBalance(legacyMember?.user_id, -amount);
      if (item.source === "savings_account") addSavingsBalance(item.source_savings_id, -amount);
      else addSavingsBalance(savingsAccountByLegacyKey(item.source)?.id, -amount);
      if (item.date.startsWith(monthKey)) monthOutcome += amount;
    }
  });

  state.transfers.forEach((item) => {
    const amount = Number(item.amount);
    addMemberBalance(transferMemberId(item, "from"), -amount);
    addSavingsBalance(transferSavingsId(item, "from"), -amount);
    addMemberBalance(transferMemberId(item, "to"), amount);
    addSavingsBalance(transferSavingsId(item, "to"), amount);
  });

  state.adjustments.forEach((item) => {
    const delta = Number(item.delta);
    if (item.balance_key === "member") addMemberBalance(item.member_user_id, delta);
    if (item.balance_key === "husband") addMemberBalance(legacyOwner?.user_id, delta);
    if (item.balance_key === "wife") addMemberBalance(legacyMember?.user_id, delta);
    if (item.balance_key === "savings_account") addSavingsBalance(item.savings_account_id, delta);
    else addSavingsBalance(savingsAccountByLegacyKey(item.balance_key)?.id, delta);
  });

  const assetValue = state.assets.reduce((sum, item) => sum + Number(item.current_value), 0);
  const personalCash = Object.values(memberBalances).reduce((sum, value) => sum + Number(value), 0);
  const includedSavings = state.savingsAccounts.reduce((sum, account) => (
    account.include_in_net_worth ? sum + Number(savingsAccountBalances[String(account.id)] || 0) : sum
  ), 0);
  const savings = Number(savingsAccountBalances[String(savingsAccountByLegacyKey("savings")?.id)] || 0);
  const wifeSavings = Number(savingsAccountBalances[String(savingsAccountByLegacyKey("wife_savings")?.id)] || 0);
  const education = Number(savingsAccountBalances[String(savingsAccountByLegacyKey("education")?.id)] || 0);
  const cash = personalCash + includedSavings;
  return {
    income,
    outcome,
    husband: Number(memberBalances[String(legacyOwner?.user_id)] || 0),
    wife: Number(memberBalances[String(legacyMember?.user_id)] || 0),
    memberBalances,
    savingsAccountBalances,
    savings,
    wifeSavings,
    education,
    monthIncome,
    monthOutcome,
    assetValue,
    cash,
    netWorth: cash + assetValue,
  };
}

function renderDashboard() {
  const totals = getTotals();
  const payday = getNextPaydayInfo();
  $("#totalWealth").textContent = formatRupiah(totals.netWorth);
  $("#wealthBreakdown").innerHTML = `${activeSavingsAccounts().map((account) => `
    <div><span>${escapeHtml(account.name)}${account.include_in_net_worth ? "" : " · Di luar total"}</span><strong>${formatRupiah(totals.savingsAccountBalances[String(account.id)] || 0)}</strong></div>
  `).join("")}<div><span>Nilai aset</span><strong>${formatRupiah(totals.assetValue)}</strong></div>`;
  const excludedCount = activeSavingsAccounts().filter((account) => !account.include_in_net_worth).length;
  $("#wealthFooter").textContent = `Total mencakup seluruh saldo pribadi anggota, ${activeSavingsAccounts().length - excludedCount} pos tabungan yang disertakan, dan nilai aset.${excludedCount ? ` ${excludedCount} pos ditampilkan tetapi tidak dihitung.` : ""}`;
  $("#monthIncome").textContent = formatRupiah(totals.monthIncome);
  $("#monthOutcome").textContent = formatRupiah(totals.monthOutcome);
  $("#monthDifference").textContent = formatRupiah(totals.monthIncome - totals.monthOutcome);
  $("#totalWealth").classList.toggle("negative", totals.netWorth < 0);
  $("#paydayCountdown").innerHTML = `
    <span>${payday.enabled ? "Menuju gajian" : "Menuju awal bulan"}</span>
    <strong>${payday.days} hari lagi</strong>
    <small>${payday.date.toLocaleDateString("id-ID", { day: "numeric", month: "short", year: "numeric" })}</small>`;

  const memberIcons = ["♙", "♡", "◇", "○", "☆", "♧", "△", "□"];
  const allocations = activeHouseholdMembers().map((member) => ({
    member,
    balanceKey: memberBalanceKey(member.user_id),
    label: memberBalanceLabel(member),
    value: Number(totals.memberBalances[String(member.user_id)] || 0),
    icon: memberIcons[Number(member.color_index || 0) % memberIcons.length],
  }));
  const max = Math.max(...allocations.map((item) => Math.max(item.value, 0)), 1);

  $("#allocationList").innerHTML = allocations.map((item) => {
    const unpaidBills = unpaidBillsForMember(item.member.user_id);
    const unpaidTotal = unpaidBills.reduce((sum, bill) => sum + Number(bill.amount), 0);
    const spendableBalance = Math.max(Number(item.value) - unpaidTotal, 0);
    const dailyRecommendation = Math.floor(spendableBalance / payday.days);
    const billSummary = unpaidBills.length
      ? `${unpaidBills.length} tagihan belum dibayar · ${formatRupiah(unpaidTotal)}`
      : "Ketuk untuk mengatur tagihan bulanan";
    return `
    <article class="allocation-item allocation-item-button ${item.value < 0 ? "deficit" : ""}" data-open-monthly-bills="${item.member.user_id}" role="button" tabindex="0" aria-label="Buka tagihan bulanan ${item.label}">
      <div class="allocation-icon ${memberColorClass(item.member)}">${item.icon}</div>
      <div class="allocation-data">
        <div><span>${escapeHtml(item.label)} · ${escapeHtml(item.member.display_name)}</span><strong class="${item.value < 0 ? "negative" : ""}">${formatRupiah(item.value)}${item.value < 0 ? " · Defisit" : ""}</strong></div>
        <progress class="balance-progress ${memberColorClass(item.member)}" max="${max}" value="${Math.max(item.value, 0)}" aria-label="Perbandingan saldo ${escapeHtml(item.label)}"></progress>
        <div class="daily-spending"><span>Rekomendasi pengeluaran per hari</span><strong>${formatRupiah(dailyRecommendation)}</strong></div>
        <small class="monthly-bill-summary${unpaidTotal > Number(item.value) ? " warning" : ""}">${billSummary}</small>
      </div>
    </article>`;
  }).join("");

  $$('[data-open-monthly-bills]').forEach((item) => {
    const openBills = () => openMonthlyBillsDialog(item.dataset.openMonthlyBills);
    item.addEventListener("click", openBills);
    item.addEventListener("keydown", (event) => {
      if (event.key === "Enter" || event.key === " ") {
        event.preventDefault();
        openBills();
      }
    });
  });

  const recent = state.transactions.slice(0, 5);
  $("#recentTransactions").innerHTML = recent.length
    ? recent.map(transactionRowHtml).join("")
    : emptyStateHtml("⇄", "Belum ada transaksi", "Catat income pertama untuk mulai melihat kondisi keuangan keluarga.", "income");

  $$('[data-view-recent-transaction]').forEach((row) => {
    const openRecent = () => openRecentTransaction(row.dataset.viewRecentTransaction);
    row.addEventListener("click", openRecent);
    row.addEventListener("keydown", (event) => {
      if (event.key === "Enter" || event.key === " ") {
        event.preventDefault();
        openRecent();
      }
    });
  });

  const assetPreview = state.assets.slice(0, 3);
  $("#assetSnapshot").innerHTML = assetPreview.length
    ? assetPreview.map((asset) => `
      <div class="asset-preview">
        <div class="asset-symbol">${assetSymbol(asset.asset_type)}</div>
        <div><strong>${escapeHtml(asset.name)}</strong><span>${formatQuantity(asset.quantity)} ${escapeHtml(asset.unit)}</span></div>
        <b>${formatRupiah(asset.current_value)}</b>
      </div>
    `).join("")
    : emptyStateHtml("◇", "Belum ada aset", "Tambahkan emas, tanah, perhiasan, kendaraan, atau aset lainnya.", "asset");

  bindDynamicActions();
}

function renderTransactionMonthOptions() {
  const monthNames = ["Januari", "Februari", "Maret", "April", "Mei", "Juni", "Juli", "Agustus", "September", "Oktober", "November", "Desember"];
  const transactionMonths = [...new Set(
    [currentMonthKey, ...state.transactions
      .map((item) => String(item.date).slice(0, 7))
      .filter((value) => /^\d{4}-\d{2}$/.test(value))],
  )].sort((a, b) => b.localeCompare(a));
  const options = transactionMonths.map((value) => {
    const [year, month] = value.split("-").map(Number);
    return `<option value="${value}">${monthNames[month - 1]} ${year}</option>`;
  });

  $("#transactionMonthFilter").innerHTML = `<option value="all">Semua bulan</option>${options.join("")}`;
  const availableValues = new Set(["all", ...transactionMonths]);
  if (!availableValues.has(state.transactionMonth)) state.transactionMonth = "all";
  $("#transactionMonthFilter").value = state.transactionMonth;
}

function renderTransactions() {
  const filtered = state.transactions.filter((item) => {
    const matchesType = state.transactionFilter === "all" || item.type === state.transactionFilter;
    const matchesMonth = state.transactionMonth === "all" || item.date.startsWith(state.transactionMonth);
    const matchesMember = state.transactionMemberFilter === "all" || String(item.user_id) === state.transactionMemberFilter;
    return matchesType && matchesMonth && matchesMember;
  });
  const container = $("#transactionsTable");

  if (!filtered.length) {
    const filteredByMonth = state.transactionMonth !== "all";
    container.innerHTML = emptyStateHtml(
      "⇄",
      filteredByMonth ? "Belum ada transaksi" : "Belum ada transaksi",
      filteredByMonth ? "Tidak ada transaksi pada bulan yang dipilih." : "Income dan outcome yang kalian catat akan muncul di sini.",
      "income",
    );
    bindDynamicActions();
    return;
  }

  container.innerHTML = `
    <div class="table-head"><span>TRANSAKSI</span><span>SUMBER/ALOKASI</span><span>NOMINAL</span><span></span></div>
    ${filtered.map((item) => `
      <div class="table-row viewable-row" data-view-transaction="${item.id}" role="button" tabindex="0" aria-label="Lihat detail transaksi ${escapeHtml(item.category)}">
        <div class="transaction-name">
          <div class="transaction-icon ${item.type}">${item.type === "income" ? "↙" : "↗"}</div>
          ${transactionDetailsHtml(item)}
        </div>
        <span>${item.type === "income" ? incomeAllocationSummary(item) : sourceLabel(item.source, item.source_member_id, item.source_savings_id)}</span>
        <strong class="${item.type === "income" ? "positive" : "negative"}">${item.type === "income" ? "+" : "−"}${formatRupiah(item.amount)}</strong>
        ${canManageTransaction(item) ? `<div class="row-actions">
          <button class="edit-button" data-edit-transaction="${item.id}" type="button" aria-label="Edit transaksi" title="Edit">✎</button>
          <button class="delete-button" data-delete-transaction="${item.id}" type="button" aria-label="Hapus transaksi" title="Hapus">×</button>
        </div>` : `<div class="row-actions row-actions-readonly" title="Hanya pencatat atau room master yang dapat mengubah">◌</div>`}
      </div>
    `).join("")}
  `;

  $$("[data-delete-transaction]").forEach((button) => {
    button.addEventListener("click", () => deleteTransaction(button.dataset.deleteTransaction));
  });
  $$("[data-edit-transaction]").forEach((button) => {
    button.addEventListener("click", () => editTransaction(button.dataset.editTransaction));
  });

  $$("[data-view-transaction]").forEach((row) => {
    const openDetail = (event) => {
      if (event.target.closest(".row-actions")) return;
      openTransactionDetail(row.dataset.viewTransaction);
    };
    row.addEventListener("click", openDetail);
    row.addEventListener("keydown", (event) => {
      if ((event.key === "Enter" || event.key === " ") && !event.target.closest(".row-actions")) {
        event.preventDefault();
        openTransactionDetail(row.dataset.viewTransaction);
      }
    });
  });
}

function renderHistoryChart() {
  const chartType = state.transactionFilter === "income" ? "income" : "outcome";
  const relevant = state.transactions.filter((item) => {
    const matchesType = item.type === chartType;
    const matchesMonth = state.transactionMonth === "all" || item.date.startsWith(state.transactionMonth);
    const matchesMember = state.transactionMemberFilter === "all" || String(item.user_id) === state.transactionMemberFilter;
    return matchesType && matchesMonth && matchesMember;
  });

  const grouped = new Map();
  relevant.forEach((item) => grouped.set(item.category, (grouped.get(item.category) || 0) + Number(item.amount)));
  const categories = [...grouped.entries()]
    .map(([name, value]) => ({ name, value }))
    .sort((a, b) => b.value - a.value);
  const total = categories.reduce((sum, item) => sum + item.value, 0);
  const isIncome = chartType === "income";
  const selectedMember = memberById(state.transactionMemberFilter);
  const scopeLabel = selectedMember
    ? memberRoleLabel(selectedMember)
    : "Semua";

  $("#historyChartEyebrow").textContent = isIncome ? "RINGKASAN INCOME" : "RINGKASAN OUTCOME";
  $("#historyChartScope").textContent = scopeLabel;

  if (!total) {
    $("#historyChartContent").innerHTML = `
      <div class="chart-empty">
        <div>◌</div>
        <strong>Belum ada ${isIncome ? "pemasukan" : "pengeluaran"}</strong>
        <span>Tidak ada data pada filter yang dipilih.</span>
      </div>`;
    return;
  }

  let offset = 0;
  const segments = categories.map((item) => {
    const percentage = item.value / total * 100;
    const visiblePercentage = percentage - Math.min(0.65, percentage * 0.15);
    const segment = `<circle class="history-donut-segment" cx="110" cy="110" r="77" pathLength="100" stroke="${historyCategoryColor(item.name, chartType)}" stroke-dasharray="${visiblePercentage} ${100 - visiblePercentage}" stroke-dashoffset="${-offset}"><title>${escapeHtml(item.name)}: ${formatRupiah(item.value)} (${formatPercentage(percentage)})</title></circle>`;
    offset += percentage;
    return segment;
  }).join("");

  $("#historyChartContent").innerHTML = `
    <div class="history-chart-layout">
      <div class="history-donut-wrap">
        <svg class="history-donut" viewBox="0 0 220 220" role="img" aria-label="${isIncome ? "Komposisi pemasukan" : "Komposisi pengeluaran"} berdasarkan kategori">
          <circle class="history-donut-track" cx="110" cy="110" r="77"></circle>
          ${segments}
        </svg>
        <div class="history-donut-center"><span>Total ${isIncome ? "income" : "outcome"}</span><strong>${formatRupiah(total)}</strong></div>
      </div>
      <div class="history-chart-legend">
        ${categories.map((item) => {
          const percentage = item.value / total * 100;
          const colorClass = `chart-color-${historyCategoryColorIndex(item.name, chartType)}`;
          return `<div class="chart-legend-row ${colorClass}"><i></i><div><strong>${escapeHtml(item.name)}</strong><span>${formatPercentage(percentage)}</span></div><b>${formatRupiah(item.value)}</b></div>`;
        }).join("")}
      </div>
    </div>`;
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
          <div class="row-actions">
            <button class="edit-button" data-edit-asset="${asset.id}" type="button" aria-label="Edit aset" title="Edit">✎</button>
            <button class="delete-button" data-delete-asset="${asset.id}" type="button" aria-label="Hapus aset" title="Hapus">×</button>
          </div>
        </div>
        <span>${escapeHtml(asset.asset_type.toUpperCase())}</span>
        <h3>${escapeHtml(asset.name)}</h3>
        <p>${formatQuantity(asset.quantity)} ${escapeHtml(asset.unit)}${asset.notes ? ` · ${escapeHtml(asset.notes)}` : ""}</p>
        <div class="asset-values">
          <div><span>Total harga beli</span><strong>${formatRupiah(asset.purchase_value)}</strong><small>${formatRupiah(Number(asset.purchase_value) / Number(asset.quantity))} / ${escapeHtml(asset.unit)}</small></div>
          <div><span>Total harga jual</span><strong>${formatRupiah(asset.current_value)}</strong><small>${formatRupiah(Number(asset.current_value) / Number(asset.quantity))} / ${escapeHtml(asset.unit)}</small></div>
        </div>
      </article>
    `).join("")
    : emptyStateHtml("◇", "Belum ada aset", "Mulai dari emas, tanah, perhiasan, kendaraan, atau aset lainnya.", "asset");

  $$("[data-delete-asset]").forEach((button) => {
    button.addEventListener("click", () => deleteAsset(button.dataset.deleteAsset));
  });
  $$("[data-edit-asset]").forEach((button) => {
    button.addEventListener("click", () => editAsset(button.dataset.editAsset));
  });
  bindDynamicActions();
}

function transactionFinancialSignature(record = {}) {
  const memberAllocations = Object.fromEntries(
    Object.entries(record.member_allocations || {}).sort(([left], [right]) => left.localeCompare(right)),
  );
  const savingsAllocations = Object.fromEntries(
    Object.entries(record.savings_allocations || {}).sort(([left], [right]) => left.localeCompare(right)),
  );
  return JSON.stringify({
    type: record.type ?? null,
    amount: Number(record.amount || 0),
    date: record.date ?? null,
    source: record.source ?? null,
    source_member_id: record.source_member_id ?? null,
    source_savings_id: record.source_savings_id ?? null,
    husband_allocation: Number(record.husband_allocation || 0),
    wife_allocation: Number(record.wife_allocation || 0),
    savings_allocation: Number(record.savings_allocation || 0),
    wife_savings_allocation: Number(record.wife_savings_allocation || 0),
    education_allocation: Number(record.education_allocation || 0),
    member_allocations: memberAllocations,
    savings_allocations: savingsAllocations,
  });
}

function isImportantFinancialLog(log) {
  if (log.entity_type === "transfer" || log.entity_type === "adjustment") return true;
  if (log.entity_type !== "transaction") return false;
  if (log.action !== "update") return true;
  const before = log.details?.before;
  const after = log.details?.after;
  if (!before || !after) return true;
  return transactionFinancialSignature(before) !== transactionFinancialSignature(after);
}

function importantFinancialLogs() {
  return state.auditLogs.filter(isImportantFinancialLog);
}

function logMonthKey(log) {
  const date = new Date(log.created_at);
  if (Number.isNaN(date.getTime())) return "";
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}`;
}

function renderLogMonthOptions() {
  const monthNames = ["Januari", "Februari", "Maret", "April", "Mei", "Juni", "Juli", "Agustus", "September", "Oktober", "November", "Desember"];
  const logMonths = [...new Set([currentMonthKey, ...importantFinancialLogs().map(logMonthKey).filter(Boolean)])]
    .sort((left, right) => right.localeCompare(left));
  $("#logsMonthFilter").innerHTML = `<option value="all">Semua bulan</option>${logMonths.map((value) => {
    const [year, month] = value.split("-").map(Number);
    return `<option value="${value}">${monthNames[month - 1]} ${year}</option>`;
  }).join("")}`;
  if (state.logsMonth !== "all" && !logMonths.includes(state.logsMonth)) state.logsMonth = currentMonthKey;
  $("#logsMonthFilter").value = state.logsMonth;
}

function renderLogs() {
  const container = $("#logsList");
  const importantLogs = importantFinancialLogs();
  const filteredLogs = importantLogs.filter((log) => state.logsMonth === "all" || logMonthKey(log) === state.logsMonth);
  if (!filteredLogs.length) {
    container.innerHTML = `
      <div class="empty-state">
        <div class="empty-icon">≡</div>
        <h4>Belum ada perubahan saldo</h4>
        <p>${importantLogs.length ? "Tidak ada perubahan keuangan pada bulan yang dipilih." : "Income, outcome, transfer, dan penyesuaian saldo penting akan tampil di sini."}</p>
      </div>`;
    return;
  }

  container.innerHTML = filteredLogs.map((log) => {
    const member = memberById(log.user_id);
    const fallbackName = log.user_id === state.user?.id ? (usernameFromEmail(state.user.email) || "Pengguna") : "Pengguna";
    const actorName = member?.display_name || fallbackName;
    const role = memberColorClass(member);
    return `
      <article class="log-row">
        <div class="log-icon ${escapeHtml(log.action)}">${logIcon(log)}</div>
        <div class="log-copy">
          <strong>${escapeHtml(log.summary)}</strong>
          <span>${logDetail(log)}</span>
          <div><time datetime="${escapeHtml(log.created_at)}">${formatDateTime(log.created_at)}</time><small class="member-name ${role}">${escapeHtml(actorName)}</small></div>
        </div>
        <b class="log-action">${escapeHtml(logActionLabel(log.action))}</b>
      </article>`;
  }).join("");
}

function logDetail(log) {
  const details = log.details || {};
  const record = details.after || details.before || {};
  if (log.entity_type === "transfer") {
    return `${escapeHtml(sourceLabel(record.from_balance, record.from_member_id, record.from_savings_account_id))} → ${escapeHtml(sourceLabel(record.to_balance, record.to_member_id, record.to_savings_account_id))} · ${formatRupiah(record.amount)}`;
  }
  if (log.entity_type === "adjustment") {
    return `${escapeHtml(sourceLabel(record.balance_key, record.member_user_id, record.savings_account_id))}: ${formatRupiah(record.previous_balance)} → ${formatRupiah(record.new_balance)}${record.notes ? ` · ${escapeHtml(record.notes)}` : ""}`;
  }
  if (log.entity_type === "monthly_bill") {
    return `${escapeHtml(record.name || "Tagihan bulanan")} · ${formatRupiah(record.amount)} · Tanggal berlangganan ${Number(record.subscription_day) || "—"}`;
  }
  if (log.entity_type === "bill_payment") {
    const month = record.billing_month ? formatBillingMonth(record.billing_month) : "bulan berjalan";
    return `${escapeHtml(details.bill_name || "Tagihan bulanan")} · ${escapeHtml(month)}`;
  }
  if (log.entity_type === "transaction") {
    return `${escapeHtml(record.category || "Transaksi")} · ${formatRupiah(record.amount)}`;
  }
  if (log.entity_type === "asset") {
    return `${escapeHtml(record.name || "Aset")} · ${formatRupiah(record.current_value)}`;
  }
  if (log.entity_type === "family_member") {
    return escapeHtml(details.display_name || details.family_role || "Perubahan anggota keluarga");
  }
  return "Perubahan data keluarga";
}

function logIcon(log) {
  if (log.entity_type === "transfer") return "⇄";
  if (log.entity_type === "adjustment") return "±";
  if (log.entity_type === "monthly_bill") return "↻";
  if (log.entity_type === "bill_payment") return "✓";
  if (log.entity_type === "asset") return "◇";
  if (log.entity_type === "family_member") return "♧";
  if (log.action === "delete") return "×";
  if (log.action === "update") return "✎";
  return "+";
}

function logActionLabel(action) {
  if (action === "create") return "Ditambah";
  if (action === "update") return "Diubah";
  if (action === "delete") return "Dihapus";
  if (action === "transfer") return "Transfer";
  if (action === "adjustment") return "Penyesuaian";
  return "Aktivitas";
}

function transactionRowHtml(item) {
  return `
    <div class="recent-row viewable-row" data-view-recent-transaction="${item.id}" role="button" tabindex="0" aria-label="Buka detail transaksi ${escapeHtml(item.category)}">
      <div class="transaction-icon ${item.type}">${item.type === "income" ? "↙" : "↗"}</div>
      ${transactionDetailsHtml(item)}
      <b class="${item.type === "income" ? "positive" : "negative"}">${item.type === "income" ? "+" : "−"}${formatRupiah(item.amount)}</b>
    </div>
  `;
}

function openRecentTransaction(id) {
  const transaction = state.transactions.find((item) => String(item.id) === String(id));
  if (!transaction) {
    showToast("Transaksi tidak ditemukan.", "error");
    return;
  }
  openTransactionDetail(transaction.id);
}

function transactionMember(item) {
  return memberById(item.user_id);
}

function transactionDetailsHtml(item) {
  const member = transactionMember(item);
  const role = memberColorClass(member);
  const roleLabel = memberRoleLabel(member);
  const description = item.description || (item.type === "income" ? "Pemasukan keluarga" : "Pengeluaran keluarga");

  return `
    <div class="transaction-details">
      <strong>${escapeHtml(item.category)}</strong>
      <span class="transaction-description">${escapeHtml(description)}</span>
      <time datetime="${escapeHtml(item.date)}">${formatDate(item.date, true)}</time>
      <small class="member-name ${role}" title="Role pencatat">${escapeHtml(roleLabel)}</small>
    </div>
  `;
}

function transactionDisplayName(item) {
  const member = transactionMember(item);
  const fallbackName = item.user_id === state.user?.id ? (usernameFromEmail(state.user.email) || "Pengguna") : "Pengguna";
  return member?.display_name || fallbackName;
}

function transactionMemberAllocations(transaction) {
  const allocations = { ...(transaction.member_allocations || {}) };
  const legacyOwner = state.householdMembers
    .filter((member) => member.system_role === "owner")
    .sort((a, b) => String(a.joined_at).localeCompare(String(b.joined_at)))[0];
  const legacyMember = state.householdMembers
    .filter((member) => member.system_role === "member")
    .sort((a, b) => String(a.joined_at).localeCompare(String(b.joined_at)))[0];
  if (legacyOwner && Number(transaction.husband_allocation || 0)) {
    allocations[legacyOwner.user_id] = Number(allocations[legacyOwner.user_id] || 0) + Number(transaction.husband_allocation);
  }
  if (legacyMember && Number(transaction.wife_allocation || 0)) {
    allocations[legacyMember.user_id] = Number(allocations[legacyMember.user_id] || 0) + Number(transaction.wife_allocation);
  }
  return allocations;
}

function transactionSavingsAllocations(transaction) {
  const allocations = { ...(transaction.savings_allocations || {}) };
  const addLegacy = (legacyKey, amount) => {
    const account = savingsAccountByLegacyKey(legacyKey);
    if (!account || !Number(amount || 0)) return;
    allocations[account.id] = Number(allocations[account.id] || 0) + Number(amount);
  };
  addLegacy("savings", transaction.savings_allocation);
  addLegacy("wife_savings", transaction.wife_savings_allocation);
  addLegacy("education", transaction.education_allocation);
  return allocations;
}

function incomeAllocationSummary(transaction) {
  const labels = Object.entries(transactionMemberAllocations(transaction))
    .filter(([, amount]) => Number(amount) > 0)
    .map(([userId]) => memberRoleLabel(memberById(userId)) === "None" ? memberById(userId)?.display_name : memberRoleLabel(memberById(userId)));
  Object.entries(transactionSavingsAllocations(transaction))
    .filter(([, amount]) => Number(amount) > 0)
    .forEach(([accountId]) => labels.push(savingsAccountById(accountId)?.name || "Tabungan"));
  return labels.filter(Boolean).join(" · ") || "Pembagian income";
}

function openTransactionDetail(id) {
  const transaction = state.transactions.find((item) => String(item.id) === String(id));
  if (!transaction) {
    showToast("Transaksi tidak ditemukan.", "error");
    return;
  }

  const isIncome = transaction.type === "income";
  const typeElement = $("#detailTransactionType");
  typeElement.textContent = isIncome ? "INCOME" : "OUTCOME";
  typeElement.className = `detail-type ${transaction.type}`;
  const amountElement = $("#detailTransactionAmount");
  amountElement.textContent = `${isIncome ? "+" : "−"}${formatRupiah(transaction.amount)}`;
  amountElement.className = `detail-amount ${isIncome ? "positive" : "negative"}`;

  const basicDetails = `
    <div class="detail-field"><span>Kategori</span><strong>${escapeHtml(transaction.category)}</strong></div>
    <div class="detail-field"><span>Tanggal</span><strong>${formatDate(transaction.date, true)}</strong></div>
    <div class="detail-field detail-field-full"><span>Keterangan</span><strong>${escapeHtml(transaction.description || (isIncome ? "Pemasukan keluarga" : "Pengeluaran keluarga"))}</strong></div>
    <div class="detail-field"><span>Dicatat oleh</span><strong>${escapeHtml(transactionDisplayName(transaction))}</strong></div>`;

  const financeDetails = isIncome
    ? `<section class="detail-allocation detail-field-full"><span>Pembagian income</span><div>
        ${Object.entries(transactionMemberAllocations(transaction)).filter(([, amount]) => Number(amount) > 0).map(([userId, amount]) => {
          const member = memberById(userId);
          return `<p><span>${escapeHtml(memberBalanceLabel(member))}${member?.is_active ? "" : " (akses dihapus)"}</span><strong>${formatRupiah(amount)}</strong></p>`;
        }).join("")}
        ${Object.entries(transactionSavingsAllocations(transaction)).filter(([, amount]) => Number(amount) > 0).map(([accountId, amount]) => `<p><span>${escapeHtml(savingsAccountById(accountId)?.name || "Tabungan diarsipkan")}</span><strong>${formatRupiah(amount)}</strong></p>`).join("")}
      </div></section>`
    : `<div class="detail-field"><span>Sumber dana</span><strong>${escapeHtml(sourceLabel(transaction.source, transaction.source_member_id, transaction.source_savings_id))}</strong></div>`;

  $("#transactionDetailBody").innerHTML = basicDetails + financeDetails;
  openModal($("#transactionDetailDialog"));
}

function closeTransactionDetailFromBackdrop(event) {
  const dialog = $("#transactionDetailDialog");
  const content = dialog.querySelector(".transaction-detail-content");
  const bounds = content.getBoundingClientRect();
  const tappedOutside = event.clientX < bounds.left
    || event.clientX > bounds.right
    || event.clientY < bounds.top
    || event.clientY > bounds.bottom;

  if (tappedOutside) dialog.close();
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

function editTransaction(id) {
  const transaction = state.transactions.find((item) => String(item.id) === String(id));
  if (!transaction) {
    showToast("Transaksi tidak ditemukan.", "error");
    return;
  }
  if (!canManageTransaction(transaction)) {
    showToast("Hanya pencatat transaksi atau room master yang dapat mengubah data ini.", "error");
    return;
  }
  openTransactionDialog(transaction.type, transaction.id);
}

function renderMemberAllocationFields(transaction = null) {
  const values = transaction ? transactionMemberAllocations(transaction) : {};
  $("#memberAllocationFields").innerHTML = activeHouseholdMembers().map((member) => `
    <label><span>${escapeHtml(memberBalanceLabel(member))}</span><div class="money-field small"><b>Rp</b><input data-member-allocation="${member.user_id}" inputmode="numeric" placeholder="0" value="${formatNumberInput(values[member.user_id] || 0)}" /></div></label>
  `).join("");
}

function renderSavingsAllocationFields(transaction = null) {
  const values = transaction ? transactionSavingsAllocations(transaction) : {};
  const visibleAccounts = state.savingsAccounts.filter((account) => !account.is_archived || Number(values[account.id] || 0) > 0);
  $("#savingsAllocationFields").innerHTML = visibleAccounts.map((account) => `
    <label><span>${escapeHtml(account.name)}${account.is_archived ? " · Diarsipkan" : ""}</span><div class="money-field small"><b>Rp</b><input data-savings-allocation="${account.id}" inputmode="numeric" placeholder="0" value="${formatNumberInput(values[account.id] || 0)}" ${account.is_archived ? "readonly" : ""} /></div></label>
  `).join("");
}

function legacySourceMemberId(source) {
  const systemRole = source === "husband" ? "owner" : source === "wife" ? "member" : null;
  if (!systemRole) return null;
  return state.householdMembers
    .filter((member) => member.system_role === systemRole)
    .sort((a, b) => String(a.joined_at).localeCompare(String(b.joined_at)))[0]?.user_id || null;
}

function openTransactionDialog(mode, transactionId = null) {
  state.transactionMode = mode;
  state.editingTransactionId = transactionId;
  $("#transactionForm").reset();
  $("#transactionAmount").readOnly = false;
  $("#transactionDate").value = today;
  const isEditing = transactionId !== null;
  $("#transactionDialogTitle").textContent = isEditing
    ? `Edit ${mode}`
    : mode === "income" ? "Catat income" : "Catat outcome";
  $("#transactionDialogCopy").textContent = isEditing
    ? "Perbarui data transaksi lalu simpan perubahan."
    : mode === "income"
      ? "Bagi pemasukan untuk anggota keluarga dan pos tabungan yang aktif."
      : "Catat pengeluaran dan pilih sumber dananya.";
  $("#incomeAllocation").classList.toggle("hidden", mode !== "income");
  $("#outcomeSourceGroup").classList.toggle("hidden", mode !== "outcome");
  renderMemberAllocationFields(isEditing ? state.transactions.find((item) => String(item.id) === String(transactionId)) : null);
  renderSavingsAllocationFields(isEditing ? state.transactions.find((item) => String(item.id) === String(transactionId)) : null);
  $("#outcomeSource").innerHTML = balanceOptionsHtml(null, true);

  const categories = mode === "income" ? incomeCategories : outcomeCategories;
  $("#transactionCategory").innerHTML = `<option value="">Pilih kategori</option>${categories.map((item) => `<option>${item}</option>`).join("")}`;
  const saveButton = $("#saveTransactionButton");
  delete saveButton.dataset.originalText;
  saveButton.textContent = isEditing ? "Simpan perubahan" : "Simpan transaksi";

  if (isEditing) {
    const transaction = state.transactions.find((item) => String(item.id) === String(transactionId));
    if (!transaction) return;
    $("#transactionAmount").value = formatNumberInput(transaction.amount);
    $("#transactionDate").value = transaction.date;
    $("#transactionCategory").value = transaction.category;
    $("#transactionDescription").value = transaction.description || "";
    if (mode !== "income") {
      const sourceKey = transaction.source === "member"
        ? memberBalanceKey(transaction.source_member_id)
        : ["husband", "wife"].includes(transaction.source)
          ? memberBalanceKey(legacySourceMemberId(transaction.source))
          : transaction.source === "savings_account"
            ? savingsBalanceKey(transaction.source_savings_id)
            : savingsBalanceKey(savingsAccountByLegacyKey(transaction.source)?.id);
      const sourceAccount = transaction.source === "savings_account"
        ? savingsAccountById(transaction.source_savings_id)
        : savingsAccountByLegacyKey(transaction.source);
      if (sourceAccount?.is_archived) {
        $("#outcomeSource").insertAdjacentHTML("beforeend", `<option value="${sourceKey}">${escapeHtml(sourceAccount.name)} · Diarsipkan</option>`);
        $("#transactionAmount").readOnly = true;
      }
      $("#outcomeSource").value = sourceKey;
    }
  }
  updateAllocationStatus();
  openModal($("#transactionDialog"));
}

async function saveTransaction(event) {
  event.preventDefault();
  const amount = parseNumber($("#transactionAmount").value);
  const isEditing = state.editingTransactionId !== null;
  const editingTransaction = isEditing ? state.transactions.find((item) => String(item.id) === String(state.editingTransactionId)) : null;
  const memberAllocations = Object.fromEntries(
    $$('[data-member-allocation]').map((input) => [input.dataset.memberAllocation, parseNumber(input.value)]).filter(([, value]) => value > 0),
  );
  const personalAllocated = Object.values(memberAllocations).reduce((sum, value) => sum + value, 0);
  const savingsAllocations = Object.fromEntries(
    $$('[data-savings-allocation]').map((input) => [input.dataset.savingsAllocation, parseNumber(input.value)]).filter(([, value]) => value > 0),
  );
  const savingsAllocated = Object.values(savingsAllocations).reduce((sum, value) => sum + value, 0);
  const archivedLegacyAllocations = { savings: 0, wife_savings: 0, education: 0 };
  if (state.transactionMode === "income" && editingTransaction) {
    ["savings", "wife_savings", "education"].forEach((legacyKey) => {
      const account = savingsAccountByLegacyKey(legacyKey);
      if (!account?.is_archived) return;
      const field = legacyKey === "savings" ? "savings_allocation" : `${legacyKey}_allocation`;
      archivedLegacyAllocations[legacyKey] = Number(editingTransaction[field] || 0);
      const originalDynamicValue = Number(editingTransaction.savings_allocations?.[account.id] || 0);
      if (originalDynamicValue > 0) savingsAllocations[account.id] = originalDynamicValue;
      else delete savingsAllocations[account.id];
    });
  }

  if (amount <= 0) {
    showToast("Nominal harus lebih dari nol.", "error");
    return;
  }
  if (state.transactionMode === "income" && personalAllocated + savingsAllocated !== amount) {
    showToast("Total pembagian harus sama dengan nominal income.", "error");
    return;
  }

  const button = $("#saveTransactionButton");
  setButtonBusy(button, true, "Menyimpan…");
  const selectedSource = state.transactionMode === "outcome" ? $("#outcomeSource").value : null;
  const personalSource = selectedSource?.startsWith("member:");
  const savingsSource = selectedSource?.startsWith("saving:");
  const selectedSavingsAccount = savingsSource ? savingsAccountById(selectedSource.slice(7)) : null;
  const preserveArchivedLegacySource = Boolean(
    savingsSource
    && selectedSavingsAccount?.is_archived
    && ["savings", "wife_savings", "education"].includes(editingTransaction?.source),
  );
  const payload = {
    household_id: state.household.id,
    type: state.transactionMode,
    amount,
    date: $("#transactionDate").value,
    category: $("#transactionCategory").value,
    description: $("#transactionDescription").value.trim(),
    source: state.transactionMode === "outcome" ? (personalSource ? "member" : preserveArchivedLegacySource ? editingTransaction.source : savingsSource ? "savings_account" : selectedSource) : null,
    source_member_id: personalSource ? selectedSource.slice(7) : null,
    source_savings_id: savingsSource && !preserveArchivedLegacySource ? selectedSource.slice(7) : null,
    member_allocations: state.transactionMode === "income" ? memberAllocations : {},
    savings_allocations: state.transactionMode === "income" ? savingsAllocations : {},
    husband_allocation: 0,
    wife_allocation: 0,
    savings_allocation: archivedLegacyAllocations.savings,
    wife_savings_allocation: archivedLegacyAllocations.wife_savings,
    education_allocation: archivedLegacyAllocations.education,
  };
  if (!isEditing) payload.user_id = state.user.id;

  const insufficientBalance = projectedNegativeBalance(payload, isEditing ? state.editingTransactionId : null);
  if (insufficientBalance) {
    showToast(`Saldo ${sourceLabel(insufficientBalance)} tidak mencukupi.`, "error");
    setButtonBusy(button, false);
    return;
  }
  const personalDeficit = projectedPersonalDeficit(payload, isEditing ? state.editingTransactionId : null);
  if (personalDeficit && !confirm(`${sourceLabel("member", personalDeficit.userId)} akan menjadi ${formatRupiah(personalDeficit.balance)} (defisit). Tetap simpan transaksi?`)) {
    setButtonBusy(button, false);
    return;
  }

  const query = supabase.from("transactions");
  const { error } = isEditing
    ? await query
      .update(payload)
      .eq("id", state.editingTransactionId)
      .eq("household_id", state.household.id)
    : await query.insert(payload);
  if (error) {
    showToast(error.message, "error");
  } else {
    $("#transactionDialog").close();
    showToast(isEditing
      ? "Transaksi berhasil diperbarui."
      : state.transactionMode === "income" ? "Income berhasil dibagikan dan disimpan." : "Outcome berhasil disimpan.");
    state.editingTransactionId = null;
    await loadFinanceData();
  }
  setButtonBusy(button, false);
}

function updateAllocationStatus() {
  const amount = parseNumber($("#transactionAmount").value);
  const allocated = $$('[data-member-allocation]').reduce((sum, input) => sum + parseNumber(input.value), 0)
    + $$('[data-savings-allocation]').reduce((sum, input) => sum + parseNumber(input.value), 0);
  const remaining = amount - allocated;
  const status = $("#allocationRemaining");
  status.textContent = remaining === 0 ? "Pas" : `Sisa ${formatRupiah(remaining)}`;
  status.classList.toggle("balanced", remaining === 0);
  $("#saveTransactionButton").disabled = state.transactionMode === "income" && remaining !== 0;
}

function openTransferDialog() {
  $("#transferForm").reset();
  $("#transferDate").value = today;
  $("#transferSource").innerHTML = balanceOptionsHtml(null, true);
  $("#transferSource").value = memberBalanceKey(state.user.id);
  updateTransferFields();
  openModal($("#transferDialog"));
}

function updateTransferFields() {
  const source = $("#transferSource").value || memberBalanceKey(state.user.id);
  const previousDestination = $("#transferDestination").value;
  $("#transferDestination").innerHTML = balanceOptionsHtml(source);
  if (previousDestination && previousDestination !== source) $("#transferDestination").value = previousDestination;
  $("#transferAvailable").textContent = formatRupiah(balanceValue(getTotals(), source));
}

async function saveTransfer(event) {
  event.preventDefault();
  const source = $("#transferSource").value;
  const destination = $("#transferDestination").value;
  const amount = parseNumber($("#transferAmount").value);
  const available = balanceValue(getTotals(), source);

  if (!source || !destination || source === destination) {
    showToast("Pilih dua pos saldo yang berbeda.", "error");
    return;
  }
  if (amount <= 0) {
    showToast("Nominal transfer harus lebih dari nol.", "error");
    return;
  }
  if (!source.startsWith("member:") && amount > available) {
    showToast(`Saldo ${sourceLabel(source)} tidak mencukupi.`, "error");
    return;
  }
  if (source.startsWith("member:") && available - amount < 0
      && !confirm(`${sourceLabel("member", source.slice(7))} akan menjadi ${formatRupiah(available - amount)} (defisit). Tetap transfer?`)) {
    return;
  }

  const button = $("#saveTransferButton");
  setButtonBusy(button, true, "Mentransfer…");
  const { error } = await supabase.rpc("create_balance_transfer", {
    p_from_balance: source,
    p_to_balance: destination,
    p_amount: amount,
    p_date: $("#transferDate").value,
    p_notes: $("#transferNotes").value.trim(),
  });
  if (error) {
    showToast(error.message, "error");
  } else {
    $("#transferDialog").close();
    showToast("Transfer saldo berhasil.");
    await loadFinanceData();
  }
  setButtonBusy(button, false);
}

function openAdjustmentDialog() {
  $("#adjustmentForm").reset();
  $("#adjustmentBalance").innerHTML = balanceOptionsHtml(null, true);
  $("#adjustmentBalance").value = memberBalanceKey(state.user.id);
  updateAdjustmentFields();
  openModal($("#adjustmentDialog"));
}

function updateAdjustmentFields() {
  const balanceKey = $("#adjustmentBalance").value || memberBalanceKey(state.user.id);
  const current = balanceValue(getTotals(), balanceKey);
  $("#adjustmentCurrent").textContent = formatRupiah(current);
  $("#adjustmentNewBalance").value = formatSignedNumberInput(current);
  $("#adjustmentDelta").value = "0";
  setAdjustmentOperator("add", false);
  updateAdjustmentEquation(current, 0, current);
}

function setAdjustmentOperator(operator, synchronize = true) {
  state.adjustmentOperator = operator === "subtract" ? "subtract" : "add";
  $$('[data-adjustment-operator]').forEach((button) => {
    const active = button.dataset.adjustmentOperator === state.adjustmentOperator;
    button.classList.toggle("active", active);
    button.setAttribute("aria-pressed", String(active));
  });
  if (synchronize) syncAdjustmentFromDelta();
}

function syncAdjustmentFromDelta() {
  const balanceKey = $("#adjustmentBalance").value || memberBalanceKey(state.user.id);
  const current = balanceValue(getTotals(), balanceKey);
  const delta = parseNumber($("#adjustmentDelta").value);
  const result = state.adjustmentOperator === "subtract" ? current - delta : current + delta;
  const invalid = result < 0 && !balanceKey.startsWith("member:");

  $("#adjustmentNewBalance").value = formatSignedNumberInput(invalid ? 0 : result);
  $("#adjustmentEntry").classList.toggle("has-error", invalid);
  updateAdjustmentEquation(current, delta, result, invalid);
}

function syncAdjustmentFromNewBalance() {
  const balanceKey = $("#adjustmentBalance").value || memberBalanceKey(state.user.id);
  const current = balanceValue(getTotals(), balanceKey);
  const result = parseSignedNumber($("#adjustmentNewBalance").value);
  const operator = result < current ? "subtract" : "add";
  const delta = Math.abs(result - current);

  setAdjustmentOperator(operator, false);
  $("#adjustmentDelta").value = formatNumberInputIncludingZero(delta);
  $("#adjustmentEntry").classList.remove("has-error");
  updateAdjustmentEquation(current, delta, result);
}

function updateAdjustmentEquation(current, delta, result, invalid = false) {
  const equation = $("#adjustmentEquation");
  if (invalid) {
    equation.textContent = "Pengurangan melebihi saldo saat ini.";
    return;
  }
  const symbol = state.adjustmentOperator === "subtract" ? "−" : "+";
  equation.textContent = `${formatRupiah(current)} ${symbol} ${formatRupiah(delta)} = ${formatRupiah(result)}`;
}

async function saveAdjustment(event) {
  event.preventDefault();
  const balanceKey = $("#adjustmentBalance").value;
  const newBalance = parseSignedNumber($("#adjustmentNewBalance").value);
  const currentBalance = balanceValue(getTotals(), balanceKey);
  const delta = parseNumber($("#adjustmentDelta").value);
  const notes = $("#adjustmentNotes").value.trim();

  if (!balanceKey.startsWith("member:") && state.adjustmentOperator === "subtract" && delta > currentBalance) {
    showToast("Nominal pengurangan melebihi saldo saat ini.", "error");
    return;
  }
  if (balanceKey.startsWith("member:") && newBalance < 0
      && !confirm(`${sourceLabel("member", balanceKey.slice(7))} akan menjadi ${formatRupiah(newBalance)} (defisit). Tetap simpan penyesuaian?`)) {
    return;
  }
  if (newBalance === currentBalance) {
    showToast("Saldo baru masih sama dengan saldo saat ini.", "error");
    return;
  }
  if (notes.length < 3) {
    showToast("Tuliskan alasan penyesuaian saldo.", "error");
    return;
  }

  const button = $("#saveAdjustmentButton");
  setButtonBusy(button, true, "Menyimpan…");
  const { error } = await supabase.rpc("adjust_household_balance", {
    p_balance_key: balanceKey,
    p_new_balance: newBalance,
    p_notes: notes,
  });
  if (error) {
    showToast(error.message, "error");
  } else {
    $("#adjustmentDialog").close();
    showToast("Penyesuaian saldo berhasil disimpan.");
    await loadFinanceData();
  }
  setButtonBusy(button, false);
}

function currentBillingMonthKey(referenceDate = new Date()) {
  return `${referenceDate.getFullYear()}-${String(referenceDate.getMonth() + 1).padStart(2, "0")}-01`;
}

function canEditMonthlyBillMember(userId) {
  return String(state.user?.id) === String(userId);
}

function isMonthlyBillPaid(billId) {
  return state.monthlyBillPayments.some((payment) => String(payment.monthly_bill_id) === String(billId));
}

function unpaidBillsForMember(userId) {
  return state.monthlyBills.filter((bill) => String(bill.owner_user_id) === String(userId) && !isMonthlyBillPaid(bill.id));
}

function openMonthlyBillsDialog(userId) {
  const member = memberById(userId);
  if (!member?.is_active) return;
  state.activeMonthlyBillMemberId = userId;
  closeMonthlyBillForm();
  clearMonthlyBillsError();

  const ownBalance = canEditMonthlyBillMember(userId);
  $("#monthlyBillsTitle").textContent = `${memberBalanceLabel(member)} · ${member.display_name}`;
  $("#monthlyBillsCopy").textContent = ownBalance
    ? "Tambahkan pengeluaran tetap dan tandai status pembayarannya setiap bulan."
    : `Detail tagihan ${memberBalanceLabel(member).toLowerCase()}. Kamu hanya dapat melihat data ini.`;
  $("#addMonthlyBillButton").classList.toggle("hidden", !ownBalance);
  $("#monthlyBillsAccessNote").textContent = ownBalance
    ? "Checklist hanya menjadi penanda. Pembayaran tetap dicatat manual melalui Outcome."
    : `Mode lihat · Hanya ${member.display_name} yang dapat menambah, mengubah, menghapus, atau mencentang tagihan.`;

  renderMonthlyBills();
  openModal($("#monthlyBillsDialog"));
}

function renderMonthlyBills() {
  const memberId = state.activeMonthlyBillMemberId;
  const bills = state.monthlyBills.filter((bill) => String(bill.owner_user_id) === String(memberId));
  const unpaidTotal = bills
    .filter((bill) => !isMonthlyBillPaid(bill.id))
    .reduce((sum, bill) => sum + Number(bill.amount), 0);
  const canEdit = canEditMonthlyBillMember(memberId);
  $("#monthlyBillsUnpaidTotal").textContent = formatRupiah(unpaidTotal);

  if (!bills.length) {
    $("#monthlyBillsList").innerHTML = `
      <div class="monthly-bills-empty">
        <span>↻</span>
        <strong>Belum ada tagihan bulanan</strong>
        <p>${canEdit ? "Tekan tombol Tambah untuk mencatat paket data, iCloud, atau langganan lainnya." : "Pemilik saldo belum menambahkan tagihan bulanan."}</p>
      </div>`;
    return;
  }

  $("#monthlyBillsList").innerHTML = bills.map((bill) => {
    const paid = isMonthlyBillPaid(bill.id);
    const subscription = monthlyBillSubscriptionInfo(bill, paid);
    return `
      <article class="monthly-bill-row${paid ? " paid" : ""}">
        <div class="monthly-bill-main">
          <strong>${escapeHtml(bill.name)}</strong>
          <span>${formatRupiah(bill.amount)}</span>
          ${canEdit ? `<div class="monthly-bill-actions"><button data-edit-monthly-bill="${bill.id}" type="button" aria-label="Edit ${escapeHtml(bill.name)}">✎</button><button data-delete-monthly-bill="${bill.id}" type="button" aria-label="Hapus ${escapeHtml(bill.name)}">×</button></div>` : ""}
        </div>
        <div class="monthly-bill-date">
          <span>${subscription.label}</span>
          <strong>${subscription.date.toLocaleDateString("id-ID", { day: "numeric", month: "short", year: "numeric" })}</strong>
        </div>
        <label class="monthly-bill-check${canEdit ? "" : " readonly"}" title="${paid ? "Sudah dibayar" : "Belum dibayar"}">
          <input data-toggle-monthly-bill="${bill.id}" type="checkbox" ${paid ? "checked" : ""} ${canEdit ? "" : "disabled"} />
          <span aria-hidden="true">✓</span>
          <small>${paid ? "Sudah" : "Belum"}</small>
        </label>
      </article>`;
  }).join("");

  $$('[data-toggle-monthly-bill]').forEach((input) => {
    input.addEventListener("change", () => toggleMonthlyBillPayment(input.dataset.toggleMonthlyBill, input.checked));
  });
  $$('[data-edit-monthly-bill]').forEach((button) => {
    button.addEventListener("click", () => openMonthlyBillForm(button.dataset.editMonthlyBill));
  });
  $$('[data-delete-monthly-bill]').forEach((button) => {
    button.addEventListener("click", () => deleteMonthlyBill(button.dataset.deleteMonthlyBill));
  });
}

function monthlyBillSubscriptionInfo(bill, paid) {
  const now = new Date();
  const thisMonthDate = clampedMonthDate(now.getFullYear(), now.getMonth(), Number(bill.subscription_day));
  if (paid) {
    return {
      date: clampedMonthDate(now.getFullYear(), now.getMonth() + 1, Number(bill.subscription_day)),
      label: "Berlangganan kembali",
    };
  }
  return {
    date: thisMonthDate,
    label: now > endOfLocalDay(thisMonthDate) ? "Belum dibayar sejak" : "Tanggal berlangganan",
  };
}

function clampedMonthDate(year, month, day) {
  const lastDay = new Date(year, month + 1, 0).getDate();
  return new Date(year, month, Math.min(day, lastDay));
}

function endOfLocalDay(date) {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate(), 23, 59, 59, 999);
}

function openMonthlyBillForm(billId = null) {
  if (!canEditMonthlyBillMember(state.activeMonthlyBillMemberId)) return;
  clearMonthlyBillsError();
  state.editingMonthlyBillId = billId;
  $("#monthlyBillForm").reset();
  $("#monthlyBillSubscriptionDay").value = String(new Date().getDate());
  $("#monthlyBillFormTitle").textContent = billId ? "Edit tagihan" : "Tambah tagihan";
  $("#saveMonthlyBillButton").textContent = billId ? "Simpan perubahan" : "Selesai";

  if (billId) {
    const bill = state.monthlyBills.find((item) => String(item.id) === String(billId));
    if (!bill || String(bill.owner_user_id) !== String(state.activeMonthlyBillMemberId)) return;
    $("#monthlyBillName").value = bill.name;
    $("#monthlyBillAmount").value = formatNumberInput(bill.amount);
    $("#monthlyBillSubscriptionDay").value = String(bill.subscription_day);
  }

  openModal($("#monthlyBillFormDialog"));
}

function closeMonthlyBillForm() {
  state.editingMonthlyBillId = null;
  if ($("#monthlyBillFormDialog").open) $("#monthlyBillFormDialog").close();
  $("#monthlyBillForm").reset();
  clearMonthlyBillsError();
}

async function saveMonthlyBill(event) {
  event.preventDefault();
  clearMonthlyBillsError();
  const memberId = state.activeMonthlyBillMemberId;
  if (!canEditMonthlyBillMember(memberId)) {
    showToast("Kamu hanya dapat mengubah tagihan milikmu sendiri.", "error");
    return;
  }

  const name = $("#monthlyBillName").value.trim();
  const amount = parseNumber($("#monthlyBillAmount").value);
  const subscriptionDay = Number($("#monthlyBillSubscriptionDay").value);
  if (!name || amount <= 0 || !Number.isInteger(subscriptionDay) || subscriptionDay < 1 || subscriptionDay > 31) {
    showToast("Lengkapi keterangan, nominal, dan tanggal berlangganan 1–31.", "error");
    return;
  }

  const button = $("#saveMonthlyBillButton");
  const editing = state.editingMonthlyBillId !== null;
  setButtonBusy(button, true, "Menyimpan…");
  const payload = { name, amount, subscription_day: subscriptionDay };
  const { error } = editing
    ? await supabase
      .from("monthly_bills")
      .update(payload)
      .eq("id", state.editingMonthlyBillId)
      .eq("household_id", state.household.id)
    : await supabase.from("monthly_bills").insert({
      ...payload,
      household_id: state.household.id,
      owner_user_id: state.user.id,
      balance_key: "member",
    });

  if (error) {
    showMonthlyBillsError(error, "Tagihan belum dapat disimpan.");
  } else {
    closeMonthlyBillForm();
    showToast(editing ? "Tagihan berhasil diperbarui." : "Tagihan bulanan berhasil ditambahkan.");
    await reloadFinanceAndBillsDialog();
  }
  setButtonBusy(button, false);
}

async function deleteMonthlyBill(billId) {
  if (!canEditMonthlyBillMember(state.activeMonthlyBillMemberId)) return;
  const bill = state.monthlyBills.find((item) => String(item.id) === String(billId));
  if (!bill || !confirm(`Hapus tagihan ${bill.name}?`)) return;
  const { error } = await supabase
    .from("monthly_bills")
    .delete()
    .eq("id", billId)
    .eq("household_id", state.household.id);
  if (error) showMonthlyBillsError(error, "Tagihan belum dapat dihapus.");
  else {
    showToast("Tagihan bulanan berhasil dihapus.");
    await reloadFinanceAndBillsDialog();
  }
}

async function toggleMonthlyBillPayment(billId, paid) {
  if (!canEditMonthlyBillMember(state.activeMonthlyBillMemberId)) return;
  const bill = state.monthlyBills.find((item) => String(item.id) === String(billId));
  if (!bill || String(bill.owner_user_id) !== String(state.activeMonthlyBillMemberId)) return;

  const query = supabase.from("monthly_bill_payments");
  const { error } = paid
    ? await query.insert({
      monthly_bill_id: bill.id,
      household_id: state.household.id,
      billing_month: currentBillingMonthKey(),
      marked_by: state.user.id,
    })
    : await query
      .delete()
      .eq("monthly_bill_id", bill.id)
      .eq("billing_month", currentBillingMonthKey())
      .eq("household_id", state.household.id);

  if (error) {
    showMonthlyBillsError(error, "Status pembayaran belum dapat diperbarui.");
    renderMonthlyBills();
  } else {
    showToast(paid ? "Tagihan ditandai sudah dibayar." : "Tagihan kembali ditandai belum dibayar.");
    await reloadFinanceAndBillsDialog();
  }
}

async function reloadFinanceAndBillsDialog() {
  await loadFinanceData();
  if ($("#monthlyBillsDialog").open) renderMonthlyBills();
}

function closeMonthlyBillsFromBackdrop(event) {
  const dialog = $("#monthlyBillsDialog");
  const content = dialog.querySelector(".monthly-bills-content");
  const bounds = content.getBoundingClientRect();
  const tappedOutside = event.clientX < bounds.left
    || event.clientX > bounds.right
    || event.clientY < bounds.top
    || event.clientY > bounds.bottom;
  if (tappedOutside) dialog.close();
}

function clearMonthlyBillsError() {
  [$("#monthlyBillsError"), $("#monthlyBillFormError")].forEach((element) => {
    element.textContent = "";
    element.classList.add("hidden");
  });
}

function showMonthlyBillsError(error, fallback) {
  const details = [error?.message, error?.details, error?.hint]
    .filter(Boolean)
    .filter((value, index, values) => values.indexOf(value) === index)
    .join(" · ");
  const code = error?.code ? ` [${error.code}]` : "";
  const message = `${fallback}${code}${details ? ` ${details}` : ""}`;
  const element = $("#monthlyBillFormDialog").open ? $("#monthlyBillFormError") : $("#monthlyBillsError");
  element.textContent = message;
  element.classList.remove("hidden");
  showToast(message, "error");
}

function editAsset(id) {
  const asset = state.assets.find((item) => String(item.id) === String(id));
  if (!asset) {
    showToast("Aset tidak ditemukan.", "error");
    return;
  }
  openAssetDialog(asset.id);
}

function openAssetDialog(assetId = null) {
  state.editingAssetId = assetId;
  $("#assetForm").reset();
  $("#assetQuantity").value = "1";
  const isEditing = assetId !== null;
  $("#assetDialogTitle").textContent = isEditing ? "Edit aset keluarga" : "Tambah aset keluarga";
  $("#assetDialogCopy").textContent = isEditing
    ? "Perbarui data aset agar total kekayaan tetap akurat."
    : "Simpan nilai aset agar total kekayaan selalu terpantau.";
  const saveButton = $("#saveAssetButton");
  delete saveButton.dataset.originalText;
  saveButton.textContent = isEditing ? "Simpan perubahan" : "Simpan aset";

  if (isEditing) {
    const asset = state.assets.find((item) => String(item.id) === String(assetId));
    if (!asset) return;
    $("#assetType").value = asset.asset_type;
    $("#assetName").value = asset.name;
    $("#assetQuantity").value = asset.quantity;
    $("#assetUnit").value = asset.unit;
    $("#assetPurchaseValue").value = formatNumberInput(Math.round(Number(asset.purchase_value) / Number(asset.quantity)));
    $("#assetCurrentValue").value = formatNumberInput(Math.round(Number(asset.current_value) / Number(asset.quantity)));
    $("#assetNotes").value = asset.notes || "";
  }
  updateAssetCalculation();
  openModal($("#assetDialog"));
}

function updateAssetCalculation() {
  const quantity = Number($("#assetQuantity").value) || 0;
  const unit = $("#assetUnit").value || "unit";
  const purchasePerUnit = parseNumber($("#assetPurchaseValue").value);
  const currentPerUnit = parseNumber($("#assetCurrentValue").value);
  $("#assetPurchaseLabel").textContent = `Harga beli per ${unit}`;
  $("#assetCurrentLabel").textContent = `Harga jual per ${unit}`;
  $("#assetPurchaseTotal").textContent = formatRupiah(Math.round(quantity * purchasePerUnit));
  $("#assetCurrentTotal").textContent = formatRupiah(Math.round(quantity * currentPerUnit));
}

function openModal(dialog) {
  if (!document.body.classList.contains("modal-open")) {
    state.lockedScrollY = window.scrollY;
    document.body.classList.add("modal-open");
  }
  dialog.showModal();
}

function unlockPageScroll() {
  if ($$(".modal[open]").length) return;
  document.body.classList.remove("modal-open");
  window.scrollTo(0, state.lockedScrollY);
}

async function saveAsset(event) {
  event.preventDefault();
  const button = $("#saveAssetButton");
  const quantity = Number($("#assetQuantity").value);
  const purchasePerUnit = parseNumber($("#assetPurchaseValue").value);
  const currentPerUnit = parseNumber($("#assetCurrentValue").value);
  const purchaseValue = Math.round(quantity * purchasePerUnit);
  const currentValue = Math.round(quantity * currentPerUnit);

  if (!Number.isFinite(quantity) || quantity <= 0) {
    showToast("Jumlah aset harus lebih dari nol.", "error");
    return;
  }

  setButtonBusy(button, true, "Menyimpan…");
  const payload = {
    household_id: state.household.id,
    user_id: state.user.id,
    asset_type: $("#assetType").value,
    name: $("#assetName").value.trim(),
    quantity,
    unit: $("#assetUnit").value,
    purchase_value: purchaseValue,
    current_value: currentValue,
    notes: $("#assetNotes").value.trim(),
  };

  const isEditing = state.editingAssetId !== null;
  const query = supabase.from("assets");
  const { error } = isEditing
    ? await query
      .update(payload)
      .eq("id", state.editingAssetId)
      .eq("household_id", state.household.id)
    : await query.insert(payload);
  if (error) {
    showToast(error.message, "error");
  } else {
    $("#assetDialog").close();
    showToast(isEditing ? "Aset berhasil diperbarui." : "Aset berhasil ditambahkan.");
    state.editingAssetId = null;
    await loadFinanceData();
  }
  setButtonBusy(button, false);
}

async function deleteTransaction(id) {
  const transaction = state.transactions.find((item) => String(item.id) === String(id));
  if (!transaction || !canManageTransaction(transaction)) {
    showToast("Hanya pencatat transaksi atau room master yang dapat menghapus data ini.", "error");
    return;
  }
  if (!confirm("Hapus transaksi ini? Saldo akan dihitung ulang.")) return;
  if (transaction) {
    const balances = currentBalanceMap();
    const currentBalances = { ...balances };
    applyTransactionEffect(balances, transaction, -1);
    const negativeKey = Object.entries(balances).find(([key, value]) => key.startsWith("saving:") && value < 0)?.[0];
    if (negativeKey) {
      showToast(`Transaksi tidak dapat dihapus karena saldo ${sourceLabel(negativeKey)} akan menjadi minus.`, "error");
      return;
    }
    const personalDeficit = Object.entries(balances).find(([key, value]) => key.startsWith("member:") && value < 0 && value < Number(currentBalances[key] || 0));
    if (personalDeficit && !confirm(`${sourceLabel("member", personalDeficit[0].slice(7))} akan menjadi ${formatRupiah(personalDeficit[1])} (defisit). Tetap hapus transaksi?`)) return;
  }
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

function parseSignedNumber(value) {
  const text = String(value ?? "").trim();
  const number = parseNumber(text);
  return text.startsWith("-") || text.startsWith("−") ? -number : number;
}

function formatNumberInput(value) {
  const number = parseNumber(value);
  return number ? new Intl.NumberFormat("id-ID").format(number) : "";
}

function formatNumberInputIncludingZero(value) {
  const digits = String(value ?? "").replace(/\D/g, "");
  if (!digits) return "";
  return new Intl.NumberFormat("id-ID").format(Number(digits));
}

function formatSignedNumberInput(value) {
  const text = String(value ?? "").trim();
  const negative = text.startsWith("-") || text.startsWith("−") || Number(value) < 0;
  const number = parseNumber(text);
  if (negative && number === 0 && (text === "-" || text === "−")) return "-";
  const formatted = new Intl.NumberFormat("id-ID").format(number);
  return negative && number ? `-${formatted}` : formatted;
}

function formatRupiah(value) {
  return new Intl.NumberFormat("id-ID", {
    style: "currency",
    currency: "IDR",
    maximumFractionDigits: 0,
  }).format(Number(value) || 0);
}

function formatDate(date, includeYear = false) {
  return new Date(`${date}T00:00:00`).toLocaleDateString("id-ID", {
    day: "numeric",
    month: "short",
    ...(includeYear ? { year: "numeric" } : {}),
  });
}

function formatBillingMonth(date) {
  return new Date(`${String(date).slice(0, 10)}T00:00:00`).toLocaleDateString("id-ID", {
    month: "long",
    year: "numeric",
  });
}

function formatDateTime(value) {
  return new Date(value).toLocaleString("id-ID", {
    day: "numeric",
    month: "short",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  });
}

function formatPercentage(value) {
  return `${new Intl.NumberFormat("id-ID", { maximumFractionDigits: 1 }).format(value)}%`;
}

function getNextPaydayInfo(referenceDate = new Date()) {
  const year = referenceDate.getFullYear();
  const month = referenceDate.getMonth();
  const day = referenceDate.getDate();
  const enabled = state.household?.payday_enabled !== false;
  const configuredDay = Math.min(31, Math.max(1, Number(state.household?.payday_day || 10)));
  const dateInMonth = (targetYear, targetMonth) => new Date(
    targetYear,
    targetMonth,
    Math.min(configuredDay, new Date(targetYear, targetMonth + 1, 0).getDate()),
  );
  let payday = enabled ? dateInMonth(year, month) : new Date(year, month + 1, 1);
  if (enabled && Date.UTC(year, month, day) >= Date.UTC(payday.getFullYear(), payday.getMonth(), payday.getDate())) {
    payday = dateInMonth(year, month + 1);
  }
  const currentUtc = Date.UTC(year, month, day);
  const paydayUtc = Date.UTC(payday.getFullYear(), payday.getMonth(), payday.getDate());
  const days = Math.max(1, Math.round((paydayUtc - currentUtc) / 86400000));
  return { date: payday, days, enabled };
}

function historyCategoryColor(category, type) {
  return chartColors[historyCategoryColorIndex(category, type)];
}

function historyCategoryColorIndex(category, type) {
  const categories = type === "income" ? incomeCategories : outcomeCategories;
  const index = categories.indexOf(category);
  if (index >= 0) return index % chartColors.length;
  const hash = [...String(category)].reduce((total, character) => total + character.charCodeAt(0), 0);
  return hash % chartColors.length;
}

function formatQuantity(value) {
  return new Intl.NumberFormat("id-ID", { maximumFractionDigits: 2 }).format(Number(value));
}

function sourceLabel(source, memberId = null, savingsAccountId = null) {
  if (source === "member") return memberBalanceLabel(memberById(memberId));
  if (source?.startsWith("member:")) return memberBalanceLabel(memberById(source.slice(7)));
  if (source === "savings_account") return savingsAccountById(savingsAccountId)?.name || "Tabungan diarsipkan";
  if (source?.startsWith("saving:")) return savingsAccountById(source.slice(7))?.name || "Tabungan diarsipkan";
  if (source === "husband") return memberBalanceLabel(memberById(legacySourceMemberId("husband"))) || "Uang suami";
  if (source === "wife") return memberBalanceLabel(memberById(legacySourceMemberId("wife"))) || "Uang istri";
  return savingsAccountByLegacyKey(source)?.name || "Tabungan";
}

function getBalanceOptions() {
  return [
    ...activeHouseholdMembers().map((member) => ({
      key: memberBalanceKey(member.user_id),
      label: `${memberBalanceLabel(member)} · ${member.display_name}`,
      personal: true,
    })),
    ...activeSavingsAccounts().map((account) => ({
      key: savingsBalanceKey(account.id),
      label: account.name,
      personal: false,
    })),
  ];
}

function balanceOptionsHtml(excludedKey = null, restrictPersonalSource = false) {
  return getBalanceOptions()
    .filter((item) => item.key !== excludedKey)
    .filter((item) => !restrictPersonalSource || !item.personal || isRoomMaster() || item.key === memberBalanceKey(state.user.id))
    .map((item) => `<option value="${item.key}">${item.label}</option>`)
    .join("");
}

function balanceValue(totals, key) {
  if (key?.startsWith("member:")) return Number(totals.memberBalances[key.slice(7)] || 0);
  if (key === "husband") return Number(totals.husband);
  if (key === "wife") return Number(totals.wife);
  if (key?.startsWith("saving:")) return Number(totals.savingsAccountBalances[key.slice(7)] || 0);
  const legacyAccount = savingsAccountByLegacyKey(key);
  if (legacyAccount) return Number(totals.savingsAccountBalances[String(legacyAccount.id)] || 0);
  return 0;
}

function currentBalanceMap() {
  const totals = getTotals();
  return Object.fromEntries(getBalanceOptions().map((item) => [item.key, balanceValue(totals, item.key)]));
}

function applyTransactionEffect(balances, transaction, multiplier = 1) {
  if (transaction.type === "income") {
    Object.entries(transactionMemberAllocations(transaction)).forEach(([userId, amount]) => {
      const key = memberBalanceKey(userId);
      if (Object.hasOwn(balances, key)) balances[key] += multiplier * Number(amount || 0);
    });
    Object.entries(transactionSavingsAllocations(transaction)).forEach(([accountId, amount]) => {
      const key = savingsBalanceKey(accountId);
      if (Object.hasOwn(balances, key)) balances[key] += multiplier * Number(amount || 0);
    });
  } else {
    const key = transaction.source === "member"
      ? memberBalanceKey(transaction.source_member_id)
      : transaction.source === "husband" || transaction.source === "wife"
        ? memberBalanceKey(legacySourceMemberId(transaction.source))
        : transaction.source === "savings_account"
          ? savingsBalanceKey(transaction.source_savings_id)
          : savingsBalanceKey(savingsAccountByLegacyKey(transaction.source)?.id);
    if (key && Object.hasOwn(balances, key)) balances[key] -= multiplier * Number(transaction.amount || 0);
  }
}

function projectedNegativeBalance(payload, editingId = null) {
  const balances = currentBalanceMap();
  if (editingId) {
    const previous = state.transactions.find((item) => String(item.id) === String(editingId));
    if (previous) applyTransactionEffect(balances, previous, -1);
  }
  applyTransactionEffect(balances, payload, 1);
  return Object.entries(balances).find(([key, value]) => key.startsWith("saving:") && value < 0)?.[0] || null;
}

function projectedPersonalDeficit(payload, editingId = null) {
  const balances = currentBalanceMap();
  const currentBalances = { ...balances };
  if (editingId) {
    const previous = state.transactions.find((item) => String(item.id) === String(editingId));
    if (previous) applyTransactionEffect(balances, previous, -1);
  }
  applyTransactionEffect(balances, payload, 1);
  const entry = Object.entries(balances).find(([key, value]) => key.startsWith("member:") && value < 0 && value < Number(currentBalances[key] || 0));
  return entry ? { userId: entry[0].slice(7), balance: entry[1] } : null;
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

function normalizeUsername(value) {
  return String(value || "").trim().toLowerCase();
}

function isValidUsername(value) {
  const username = normalizeUsername(value);
  return username.length >= 3 && username.length <= 30 && usernamePattern.test(username);
}

function usernameToAuthEmail(username) {
  return `${normalizeUsername(username)}@${authUsernameDomain}`;
}

function usernameFromEmail(email) {
  return String(email || "").trim().toLowerCase().split("@")[0];
}

function translateAuthError(message) {
  const lower = message.toLowerCase();
  if (lower.includes("invalid login credentials")) return "Username atau password salah.";
  if (lower.includes("email not confirmed")) return "Akun belum diaktifkan. Hubungi admin untuk mengaktifkannya.";
  if (lower.includes("already registered") || lower.includes("already been registered")) return "Username sudah digunakan.";
  if (lower.includes("rate limit") || lower.includes("too many requests")) return "Terlalu banyak percobaan. Tunggu sebentar lalu coba lagi.";
  if (lower.includes("password")) return "Password minimal 6 karakter.";
  return message;
}
