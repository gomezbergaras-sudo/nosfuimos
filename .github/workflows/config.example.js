// =====================================================================
//  NOS FUIMOS — Configuración de la app (plantilla)
//  Copia este archivo como config.js y pon tus valores reales.
//  config.js está en .gitignore: NUNCA se sube a GitHub.
//  En GitHub Pages, el workflow deploy.yml genera config.js desde los
//  Secrets del repositorio (SUPABASE_URL y SUPABASE_ANON_KEY).
// =====================================================================
window.NF_CONFIG = {
  SUPABASE_URL: "https://TU_PROYECTO.supabase.co",   // Project Settings → API → Project URL
  SUPABASE_ANON_KEY: "eyJ...",                        // Project Settings → API → anon public
  APP_NAME: "Nos Fuimos",
  MONEDA: "USD",
  // La clave service_role NO va aquí ni en ningún archivo del front.
};
