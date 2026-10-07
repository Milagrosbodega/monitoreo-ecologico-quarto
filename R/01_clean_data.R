# ==============================================================================
# Pipeline de Limpieza y Estandarización de Datos Ambientales
# Autor: Milagros Bodega Marchesini
# Entradas: data/raw/ (fisicoquimica, macroinvertebrados, datos interanuales)
# Salidas:  data/processed/ (.rds y .csv)
# ==============================================================================

# 1. Paquetes requeridos -------------------------------------------------------
library(tidyverse)
library(janitor)
library(lubridate)

# 2. Metadatos de referencia (Lagunas y Calendario) ----------------------------
# Coordenadas y nombres descriptivos según códigos F, C, S, N
geo_lagunas <- tibble(
  codigo_laguna = c("F", "C", "S", "N"),
  nombre_laguna = c("Fartet", "Chara", "Salada", "Nueva"),
  # Coordenadas decimales WGS84 de referencia (puedes ajustar a las exactas de muestreo)
  latitud       = c(41.185, 41.184, 41.184, 41.185),
  longitud      = c(1.549,  1.553,  1.550,  1.552)
)

meses_map <- c(
  "Nov" = "11", "Dic" = "12", "Ene" = "01", 
  "Feb" = "02", "Mar" = "03", "Abr" = "04", "May" = "05"
)

# 3. Limpieza de Fisicoquímica Mensual -----------------------------------------
message("Procesando datos fisicoquímicos mensuales...")

fq_raw <- read_csv(
  "data/raw/fisicoquimica_raw.csv", 
  na = c("", "NA", "-", " ", "N/A"),
  show_col_types = FALSE
)

fq_clean <- fq_raw %>%
  clean_names() %>%
  # Separar código de muestra (ej: Nov.F -> mes_str = Nov, codigo_laguna = F)
  separate(muestra, into = c("mes_str", "codigo_laguna"), sep = "\\.") %>%
  mutate(
    # Ciclo Nov-May: Nov y Dic corresponden al primer año, Ene-May al segundo
    anio = if_else(mes_str %in% c("Nov", "Dic"), "2025", "2026"),
    mes_num = meses_map[mes_str],
    fecha = ymd(paste(anio, mes_num, "15", sep = "-"))
  ) %>%
  left_join(geo_lagunas, by = "codigo_laguna") %>%
  # Limpieza de columnas y tipos numéricos
  mutate(across(where(is.character) & !c(mes_str, codigo_laguna, nombre_laguna, horario, anio, mes_num), as.numeric)) %>%
  select(fecha, anio, mes_str, codigo_laguna, nombre_laguna, latitud, longitud, everything(), -mes_num) %>%
  arrange(codigo_laguna, fecha)

# 4. Limpieza de Matriz de Macroinvertebrados ----------------------------------
message("Procesando matriz biológica de macroinvertebrados...")

macro_raw <- read_csv(
  "data/raw/macroinvertebrados_raw.csv", 
  na = c("", "NA", "-", " ", "N/A"),
  show_col_types = FALSE
)

macro_clean <- macro_raw %>%
  clean_names() %>%
  separate(muestra, into = c("mes_str", "codigo_laguna"), sep = "\\.") %>%
  mutate(
    anio = if_else(mes_str %in% c("Nov", "Dic"), "2025", "2026"),
    mes_num = meses_map[mes_str],
    fecha = ymd(paste(anio, mes_num, "15", sep = "-"))
  ) %>%
  left_join(geo_lagunas, by = "codigo_laguna") %>%
  # En conteos biológicos, celdas vacías o NAs representan conteo 0 (ausencia)
  mutate(across(where(is.numeric) & !c(latitud, longitud), ~ replace_na(.x, 0))) %>%
  select(fecha, anio, mes_str, codigo_laguna, nombre_laguna, latitud, longitud, everything(), -mes_num) %>%
  arrange(codigo_laguna, fecha)

# Identificar columnas que representan taxones
cols_no_taxa <- c("fecha", "anio", "mes_str", "codigo_laguna", "nombre_laguna", "latitud", "longitud")
taxa_cols <- setdiff(names(macro_clean), cols_no_taxa)

# Cálculo de descriptores comunitarios
metricas_macro <- macro_clean %>%
  rowwise() %>%
  mutate(
    abundancia_total = sum(c_across(all_of(taxa_cols)), na.rm = TRUE),
    riqueza_taxa = sum(c_across(all_of(taxa_cols)) > 0, na.rm = TRUE)
  ) %>%
  ungroup() %>%
  select(fecha, codigo_laguna, abundancia_total, riqueza_taxa)

# 5. Integración: Dataset Consolidado (Fisicoquímica + Bioindicadores) ----------
dataset_consolidado <- fq_clean %>%
  left_join(metricas_macro, by = c("fecha", "codigo_laguna"))

# ------------------------------------------------------------------------------
# 6. Limpieza Dinámica de Serie Histórica Interanual
# ------------------------------------------------------------------------------
message("Procesando datos interanuales de forma dinámica...")

# Leemos las primeras dos filas para capturar Periodos y Estadísticos reales
encabezado_lineas <- read_lines("data/raw/interanual_raw.csv", n_max = 2)
fila1 <- str_split(encabezado_lineas[1], ",")[[1]]
fila2 <- str_split(encabezado_lineas[2], ",")[[1]]

# Rellenar los periodos hacia la derecha (por las celdas combinadas de la fila 1)
periodos_rellenos <- fila1
for (i in 2:length(periodos_rellenos)) {
  if (periodos_rellenos[i] == "" || is.na(periodos_rellenos[i])) {
    periodos_rellenos[i] <- periodos_rellenos[i - 1]
  }
}

# Construir nombres limpios combinando estadístico y periodo (ej. media_2023_24)
nombres_dinamicos <- c("laguna", "parametro")
for (j in 3:length(fila2)) {
  est <- tolower(trimws(fila2[j]))
  per <- str_replace_all(trimws(periodos_rellenos[j]), "[-/ ]", "_")
  nombres_dinamicos <- c(nombres_dinamicos, paste(est, per, sep = "_"))
}

# Leer el contenido real saltando las dos filas de encabezado
interanual_raw <- read_csv(
  "data/raw/interanual_raw.csv",
  skip = 2,
  col_names = FALSE,
  na = c("", "NA", "-", " ", "N/A"),
  show_col_types = FALSE
)

# Asignar los nombres detectados dinámicamente
colnames(interanual_raw) <- nombres_dinamicos[1:ncol(interanual_raw)]

interanual_clean <- interanual_raw %>%
  fill(laguna, .direction = "down") %>%
  # Limpiar filas en blanco y asegurarse de conservar todos los parámetros (incluida CE)
  filter(!is.na(parametro), !parametro %in% c("min", "max", "media", "")) %>%
  # Pasar a formato tidy automáticamente para todos los periodos encontrados
  pivot_longer(
    cols = starts_with(c("min_", "max_", "media_")),
    names_to = c(".value", "periodo"),
    names_pattern = "(min|max|media)_(.*)"
  ) %>%
  mutate(
    # Restaurar formato del periodo (ej. 2023_24 a 2023-24)
    periodo = str_replace(periodo, "_", "-"),
    across(c(min, max, media), ~ as.numeric(str_replace_all(as.character(.x), ",", ".")))
  ) %>%
  filter(!is.na(media)) %>%
  arrange(laguna, parametro, periodo)

# Exportar a data/processed/
saveRDS(interanual_clean, "data/processed/interanual_clean.rds")
write_csv(interanual_clean, "data/processed/interanual_clean.csv")
message("¡Serie interanual procesada con todos los periodos y parámetros!")

# 7. Exportación a data/processed/ ---------------------------------------------
message("Guardando archivos en data/processed/...")

saveRDS(fq_clean, "data/processed/fisicoquimica_clean.rds")
saveRDS(macro_clean, "data/processed/macroinvertebrados_clean.rds")
saveRDS(dataset_consolidado, "data/processed/dataset_consolidado.rds")
saveRDS(interanual_clean, "data/processed/interanual_clean.rds")

# Exportar también en CSV para visualización externa o consulta rápida
write_csv(dataset_consolidado, "data/processed/dataset_consolidado.csv")
write_csv(interanual_clean, "data/processed/interanual_clean.csv")

message("¡Procesamiento completo! Todos los datasets están listos en data/processed/.")