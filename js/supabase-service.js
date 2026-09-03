(function () {
  'use strict';

  let client = null;
  let initialized = false;

  // Kode error terstruktur dari RPC period (supabase/period-history-migration.sql).
  // Pesannya diteruskan apa adanya agar Admin tahu penyebab pastinya
  // (mis. Closing TAT bukan 100, atau periode sudah Closing).
  // Daftar ini WAJIB memuat setiap kode yang di-raise publish_period_snapshot_v1 /
  // activate_period_snapshot_v1. Kode yang tidak terdaftar akan jatuh ke mapping
  // errcode P0001 di bawah dan salah tampil sebagai error admin/auth.
  const PERIOD_ERROR_PREFIXES = [
    'PERIOD_ALREADY_CLOSING',
    'CLOSING_TAT_INVALID',
    'CLOSING_TAT_MISSING',   // TAT Closing tidak tersedia pada payload/snapshot
    'CLOSING_TAT_MISMATCH',  // TAT metadata vs activeSnapshot tidak konsisten
    'PERIOD_CUTOFF_MISMATCH',
    'PERIOD_PAYLOAD_MISMATCH',
    'PAYLOAD_SCHEMA_MISMATCH',
    'PAYLOAD_COUNT_MISMATCH',
    'PAYLOAD_ELIGIBLE_COUNT_MISMATCH',
    'INVALID_RECORD_COUNT',
    'INVALID_ELIGIBLE_COUNT',
    'INVALID_PERIOD_STATUS',
    'INVALID_SCHEMA_VERSION',
    'INVALID_PAYLOAD',
    'INVALID_CUTOFF',
    'PUBLICATION_NOT_FOUND',
    'AUTH_REQUIRED',
    'ADMIN_REQUIRED'
  ];

  function periodErrorMessage(error) {
    const raw = error && typeof error.message === 'string' ? error.message.trim() : '';
    if (!raw) return '';
    const marker = PERIOD_ERROR_PREFIXES.find(prefix => raw.indexOf(prefix) === 0);
    if (!marker) return '';
    const detail = raw.slice(marker.length).replace(/^:\s*/, '').trim();
    return detail || raw;
  }

  function safeError(error, fallback) {
    const code = error && typeof error.code === 'string' ? error.code : '';
    const periodMessage = periodErrorMessage(error);
    if (periodMessage) return new Error(periodMessage);
    if (code === '23505') return new Error('Snapshot dengan tanggal dan revisi yang sama sudah tersedia.');
    if (code === '42501' || code === 'P0001') return new Error('Operasi ditolak. Pastikan akun Anda terdaftar sebagai admin.');
    return new Error(fallback);
  }

  // --- Helper periode -------------------------------------------------------
  // period_key kanonik = 'YYYY-MM'. Di database disimpan sebagai DATE period_month
  // (tanggal 1 bulan tsb) agar ordering & index konsisten dengan cutoff_date.
  const PERIOD_KEY_PATTERN = /^\d{4}-(0[1-9]|1[0-2])$/;

  function normalizePeriodKey(value) {
    const text = String(value == null ? '' : value).trim();
    if (PERIOD_KEY_PATTERN.test(text)) return text;
    if (/^\d{4}-(0[1-9]|1[0-2])-\d{2}/.test(text)) return text.slice(0, 7);
    throw new Error('Periode tidak valid. Gunakan format YYYY-MM.');
  }

  function periodKeyToMonthDate(value) {
    return `${normalizePeriodKey(value)}-01`;
  }

  function normalizePeriodStatus(value) {
    const text = String(value == null ? '' : value).trim().toUpperCase();
    if (text !== 'MTD' && text !== 'CLOSING') {
      throw new Error('Jenis data harus MTD atau CLOSING.');
    }
    return text;
  }

  // Bentuk baris period yang seragam untuk frontend, apa pun sumber query-nya.
  function mapPeriodRow(row) {
    if (!row) return null;
    const monthDate = String(row.period_month || '');
    return {
      id: String(row.id || ''),
      periodKey: row.period_key ? String(row.period_key) : monthDate.slice(0, 7),
      periodMonth: monthDate,
      periodStatus: String(row.period_status || 'MTD').toUpperCase(),
      periodRevisionNumber: Number(row.period_revision_number || 0) || null,
      revisionNumber: Number(row.revision_number || 0) || null,
      cutoffDate: String(row.cutoff_date || ''),
      publishedAt: String(row.published_at || ''),
      fileName: String(row.file_name || ''),
      recordCount: Number(row.record_count || 0),
      eligibleCount: Number(row.eligible_count || 0),
      dataSchemaVersion: row.data_schema_version == null ? null : row.data_schema_version,
      isActive: row.is_active === true,
      isPeriodCurrent: row.is_period_current === true
    };
  }

  function getValidatedConfig() {
    const config = window.SUPABASE_CONFIG;
    if (!config || typeof config !== 'object') {
      throw new Error('Konfigurasi Supabase belum dimuat.');
    }
    const url = String(config.url || '').trim();
    const publishableKey = String(config.publishableKey || '').trim();
    if (!url || url === 'PROJECT_URL' || !publishableKey || publishableKey === 'PUBLISHABLE_KEY') {
      throw new Error('Konfigurasi Supabase belum diisi. Lengkapi js/supabase-config.js.');
    }
    let parsedUrl;
    try {
      parsedUrl = new URL(url);
    } catch (_) {
      throw new Error('Project URL Supabase tidak valid.');
    }
    if (parsedUrl.protocol !== 'https:') throw new Error('Project URL Supabase harus menggunakan HTTPS.');
    return { url: parsedUrl.toString().replace(/\/$/, ''), publishableKey };
  }

  async function initialize() {
    if (initialized && client) return client;
    if (!window.supabase || typeof window.supabase.createClient !== 'function') {
      throw new Error('Supabase JavaScript Client gagal dimuat. Periksa koneksi internet lalu muat ulang.');
    }
    const config = getValidatedConfig();
    client = window.supabase.createClient(config.url, config.publishableKey, {
      auth: {
        persistSession: true,
        autoRefreshToken: true,
        detectSessionInUrl: true,
        storageKey: 'ranking-nasional-auth'
      }
    });
    initialized = true;
    return client;
  }

  function getClient() {
    if (!client) throw new Error('Supabase belum diinisialisasi.');
    return client;
  }

  async function getSession() {
    const { data, error } = await getClient().auth.getSession();
    if (error) throw safeError(error, 'Sesi login tidak dapat diperiksa.');
    return data.session || null;
  }

  async function signIn(email, password) {
    const { data, error } = await getClient().auth.signInWithPassword({ email, password });
    if (error) throw new Error('Email atau password tidak benar.');
    return data.session || null;
  }

  async function signOut() {
    const { error } = await getClient().auth.signOut();
    if (error) throw safeError(error, 'Logout gagal. Silakan coba lagi.');
  }

  async function checkCurrentUserIsAdmin() {
    const { data, error } = await getClient().rpc('is_current_user_admin');
    if (error) throw safeError(error, 'Status admin tidak dapat diverifikasi.');
    return data === true;
  }

  async function getActivePublishedSnapshot() {
    const { data, error } = await getClient()
      .from('published_snapshots')
      .select('id,cutoff_date,revision_number,published_at,file_name,record_count,eligible_count,data_schema_version,payload_json')
      .eq('is_active', true)
      .maybeSingle();
    if (error) throw safeError(error, 'Data nasional tidak dapat diambil.');
    return data || null;
  }

  async function getPublishedSnapshotHistory(limit) {
    const safeLimit = Math.min(30, Math.max(1, Number(limit) || 25));
    const { data, error } = await getClient()
      .from('published_snapshots')
      .select('id,cutoff_date,revision_number,published_at,file_name,record_count,eligible_count,data_schema_version,is_active')
      .order('published_at', { ascending: false })
      .limit(safeLimit);
    if (error) throw safeError(error, 'Riwayat publikasi tidak dapat diambil.');
    return data || [];
  }

  async function publishNationalSnapshot(payload, metadata) {
    const { data, error } = await getClient().rpc('publish_national_snapshot', {
      p_cutoff_date: metadata.cutoffDate,
      p_revision_number: metadata.revisionNumber,
      p_payload_json: payload,
      p_file_name: metadata.fileName,
      p_record_count: metadata.recordCount,
      p_eligible_count: metadata.eligibleCount,
      p_data_schema_version: payload.schemaVersion
    });
    if (error) throw safeError(error, 'Publikasi data nasional gagal.');
    return data;
  }

  async function activatePublishedSnapshot(snapshotId) {
    const { data, error } = await getClient().rpc('activate_published_snapshot', {
      p_snapshot_id: snapshotId
    });
    if (error) throw safeError(error, 'Snapshot tidak dapat diaktifkan kembali.');
    return data;
  }

  // ==========================================================================
  // API PERIODE (aditif — seluruh function lama di atas tidak diubah perilakunya)
  //
  // Sumber data: view public.published_period_index (security_invoker = true,
  // hanya baris is_period_current, TANPA published_by dan TANPA payload_json).
  // Satu baris per bulan = tepat satu item per bulan pada period selector.
  // ==========================================================================

  const PERIOD_INDEX_VIEW = 'published_period_index';
  const PERIOD_FEATURE_MISSING = 'PERIOD_FEATURE_MISSING';

  // Migration belum diterapkan -> view/kolom period belum ada. Frontend memakai
  // penanda ini untuk jatuh ke mode legacy (is_active) alih-alih menampilkan error.
  function isMissingPeriodObject(error) {
    const code = error && typeof error.code === 'string' ? error.code : '';
    const message = error && typeof error.message === 'string' ? error.message : '';
    return code === '42P01' || code === '42703' || code === 'PGRST205' || code === 'PGRST204'
      || /published_period_index|period_month|period_status|is_period_current/i.test(message);
  }

  function periodFeatureError() {
    const error = new Error('Fitur periode belum aktif di database. Jalankan supabase/period-history-migration.sql.');
    error.code = PERIOD_FEATURE_MISSING;
    return error;
  }

  /**
   * Daftar periode resmi (satu item per bulan), terbaru lebih dulu berdasarkan
   * period_month — BUKAN published_at (§10/§14: backfill bulan lama tidak boleh
   * menggeser default).
   */
  async function getOfficialPeriods(limit) {
    const safeLimit = Math.min(60, Math.max(1, Number(limit) || 36));
    const { data, error } = await getClient()
      .from(PERIOD_INDEX_VIEW)
      .select('id,period_month,period_key,period_status,cutoff_date,period_revision_number,revision_number,published_at,file_name,record_count,eligible_count,data_schema_version,is_active,is_period_current')
      .order('period_month', { ascending: false })
      .limit(safeLimit);
    if (error) {
      if (isMissingPeriodObject(error)) throw periodFeatureError();
      throw safeError(error, 'Daftar periode tidak dapat diambil.');
    }
    return (data || []).map(mapPeriodRow).filter(Boolean);
  }

  /**
   * Snapshot resmi (is_period_current) untuk satu period_key, LENGKAP dengan payload.
   * Tidak pernah memakai is_active — is_active hanya kompatibilitas global.
   */
  async function getOfficialPeriodSnapshot(periodKey) {
    const monthDate = periodKeyToMonthDate(periodKey);
    const { data, error } = await getClient()
      .from('published_snapshots')
      .select('id,cutoff_date,revision_number,published_at,file_name,record_count,eligible_count,data_schema_version,period_month,period_status,period_revision_number,is_period_current,is_active,payload_json')
      .eq('period_month', monthDate)
      .eq('is_period_current', true)
      .maybeSingle();
    if (error) {
      if (isMissingPeriodObject(error)) throw periodFeatureError();
      throw safeError(error, 'Data periode tidak dapat diambil.');
    }
    return data || null;
  }

  /**
   * Publikasi satu periode. Revisi publikasi dihitung BACKEND (§21) dan payload
   * metadata dinormalisasi backend (§22) — nilai yang dikirim frontend hanyalah
   * usulan, hasil final dibaca dari return value RPC.
   */
  async function publishPeriodSnapshot(payload, metadata) {
    const meta = metadata || {};
    const { data, error } = await getClient().rpc('publish_period_snapshot_v1', {
      p_payload_json: payload,
      p_cutoff_date: meta.cutoffDate,
      p_period_month: periodKeyToMonthDate(meta.periodKey || meta.cutoffDate),
      p_period_status: normalizePeriodStatus(meta.periodStatus),
      p_file_name: meta.fileName,
      p_record_count: meta.recordCount,
      p_eligible_count: meta.eligibleCount,
      p_data_schema_version: String(
        meta.dataSchemaVersion != null ? meta.dataSchemaVersion : (payload && payload.schemaVersion) || 1
      )
    });
    if (error) {
      if (isMissingPeriodObject(error)) throw periodFeatureError();
      throw safeError(error, 'Publikasi data periode gagal.');
    }
    const row = Array.isArray(data) ? data[0] : data;
    if (!row) throw new Error('Publikasi periode tidak mengembalikan hasil.');
    return {
      publicationId: String(row.out_publication_id || ''),
      periodMonth: String(row.out_period_month || ''),
      periodKey: String(row.out_period_month || '').slice(0, 7),
      periodStatus: String(row.out_period_status || '').toUpperCase(),
      periodRevisionNumber: Number(row.out_period_revision_number || 0),
      legacyRevisionNumber: Number(row.out_legacy_revision_number || 0),
      isGlobalActive: row.out_is_global_active === true
    };
  }

  /** Mengembalikan publikasi lama menjadi resmi DALAM SATU periode (admin only). */
  async function activatePeriodSnapshot(publicationId) {
    const { data, error } = await getClient().rpc('activate_period_snapshot_v1', {
      p_publication_id: publicationId
    });
    if (error) {
      if (isMissingPeriodObject(error)) throw periodFeatureError();
      throw safeError(error, 'Publikasi periode tidak dapat diaktifkan kembali.');
    }
    const row = Array.isArray(data) ? data[0] : data;
    return row || null;
  }

  /**
   * Riwayat publikasi untuk audit Admin. Bila periodKey diberikan, dibatasi pada
   * periode tersebut. published_by TIDAK PERNAH diminta.
   */
  async function getPeriodPublicationHistory(periodKey, limit) {
    const safeLimit = Math.min(50, Math.max(1, Number(limit) || 25));
    let query = getClient()
      .from('published_snapshots')
      .select('id,cutoff_date,revision_number,published_at,file_name,record_count,eligible_count,data_schema_version,period_month,period_status,period_revision_number,is_period_current,is_active');
    if (periodKey) query = query.eq('period_month', periodKeyToMonthDate(periodKey));
    const { data, error } = await query
      .order('period_month', { ascending: false })
      .order('period_revision_number', { ascending: false })
      .limit(safeLimit);
    if (error) {
      if (isMissingPeriodObject(error)) throw periodFeatureError();
      throw safeError(error, 'Riwayat publikasi periode tidak dapat diambil.');
    }
    return (data || []).map(mapPeriodRow).filter(Boolean);
  }

  function onAuthStateChange(callback) {
    const { data } = getClient().auth.onAuthStateChange((event, session) => {
      callback(event, session || null);
    });
    return data.subscription;
  }

  window.SupabaseService = Object.freeze({
    initialize,
    getClient,
    getSession,
    signIn,
    signOut,
    checkCurrentUserIsAdmin,
    getActivePublishedSnapshot,
    getPublishedSnapshotHistory,
    publishNationalSnapshot,
    activatePublishedSnapshot,
    onAuthStateChange,
    // --- API periode (aditif) ---
    PERIOD_FEATURE_MISSING,
    normalizePeriodKey,
    normalizePeriodStatus,
    getOfficialPeriods,
    getOfficialPeriodSnapshot,
    publishPeriodSnapshot,
    activatePeriodSnapshot,
    getPeriodPublicationHistory
  });
})();
