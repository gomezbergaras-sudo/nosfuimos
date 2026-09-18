// Guardar como: shared/supabase.js
// Cliente Supabase compartido por app/, admin/ y conductor/.
// Requiere que antes se cargue ../config.js y la librería:
//   <script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2"></script>
//   <script src="../config.js"></script>
//   <script src="../shared/supabase.js"></script>
(function () {
  if (!window.NF_CONFIG || !window.NF_CONFIG.SUPABASE_URL || window.NF_CONFIG.SUPABASE_URL.includes("TU_PROYECTO")) {
    document.body.innerHTML = '<p style="font-family:sans-serif;padding:2rem">Falta configurar <b>config.js</b> con la URL y la anon key de Supabase. Ver 00_GUIA_DE_INSTALACION.</p>';
    throw new Error("NF_CONFIG no configurado");
  }
  window.sb = supabase.createClient(window.NF_CONFIG.SUPABASE_URL, window.NF_CONFIG.SUPABASE_ANON_KEY, {
    auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true }
  });

  // Helpers de uso común
  window.NF = {
    // Sesión actual (null si no hay)
    async sesion() { const { data } = await sb.auth.getSession(); return data.session; },
    // Perfil del usuario logueado (con rol)
    async perfil() {
      const s = await NF.sesion(); if (!s) return null;
      const { data } = await sb.from("perfiles").select("*").eq("id", s.user.id).single();
      return data;
    },
    // Llamar una función de negocio y lanzar el mensaje de error legible
    async rpc(nombre, params) {
      const { data, error } = await sb.rpc(nombre, params || {});
      if (error) throw new Error(error.message.replace(/^.*?: /, ""));
      return data;
    },
    // Formato de dinero: 80 -> "$80"
    dinero(n) { return "$" + Number(n).toLocaleString("en-US", { minimumFractionDigits: 0, maximumFractionDigits: 2 }); },
  };
})();
