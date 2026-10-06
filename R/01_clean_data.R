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
    anio = if_else(mes_str %in% c("Nov", "Dic"), "2023", "2024"),
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
    anio = if_else(mes_str %in% c("Nov", "Dic"), "2023", "2024"),
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

# 6. Limpieza de Serie Histórica Interanual (2015 - 2023) ----------------------
message("Procesando datos interanuales...")

# Se leen los datos saltando posibles filas vacías de encabezado de Excel
interanual_raw <- read_csv(
  "data/raw/interanual_raw.csv",
  skip = 1,
  col_names = FALSE,
  na = c("", "NA", "-", " ", "N/A"),
  show_col_types = FALSE
)

# Construir nombres estructurados para la cabecera doble (4 periodos x 3 medidas)
nombres_cols <- c(
  "laguna", "parametro",
  "min_2015_16", "max_2015_16", "media_2015_16",
  "min_2018_19", "max_2018_19", "media_2018_19",
  "min_2021_22", "max_2021_22", "media_2021_22",
  "min_2022_23", "max_2022_23", "media_2022_23"
)

# Asignar nombres hasta la cantidad de columnas leídas
colnames(interanual_raw)[seq_along(nombres_cols)] <- nombres_cols

interanual_clean <- interanual_raw %>%
  # Completar los nombres de lagunas que provienen de celdas combinadas
  fill(laguna, .direction = "down") %>%
  # Limpieza de filas vacías o subtítulos residuales
  filter(!is.na(parametro), !parametro %in% c("min", "max", "media", "CE (mS/cm)")) %>%
  # Formato Tidy (pivot a largo)
  pivot_longer(
    cols = starts_with(c("min_", "max_", "media_")),
    names_to = c(".value", "periodo"),
    names_pattern = "(min|max|media)_(.*)"
  ) %>%
  mutate(
    periodo = str_replace(periodo, "_", "-"),
    across(c(min, max, media), ~ as.numeric(str_replace_all(.x, ",", ".")))
  ) %>%
  # Vincular nombres estandarizados y coordenadas
  left_join(geo_lagunas %>% select(nombre_laguna, latitud, longitud), by = c("laguna" = "nombre_laguna")) %>%
  filter(!is.na(media)) %>%
  arrange(laguna, parametro, periodo)

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