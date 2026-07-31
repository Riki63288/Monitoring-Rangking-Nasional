(function () {
  'use strict';

  let client = null;
  let initialized = false;

  function safeError(error, fallback) {
    const code = error && typeof error.code === 'string' ? error.code : '';
    if (code === '23505') return new Error('Snapshot dengan tanggal dan revisi yang sama sudah tersedia.');
    if (code === '42501' || code === 'P0001') return new Error('Operasi ditolak. Pastikan akun Anda terdaftar sebagai admin.');
    return new Error(fallback);
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
    onAuthStateChange
  });
})();
