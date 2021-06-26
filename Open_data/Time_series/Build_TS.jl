# Use at own risk!

#Script para generar series de tiempo conjeturadas de los datos abiertos oficiales.

#Módulos para cargar los datos.
using ZipFile, CSV, DataFrames, Dates

#Definimos una función para clasificar un paciente como vivo (true) o fallecido (false) dependiendo de la fecha de corte:
function clasificación_vivo(fecha_corte, row)

    #Si la fecha de defunción no está dada (missing), devolvemos vcerdadero:
    if ismissing(row[:FECHA_DEF])

        return true
    end

    #Si la fecha de defunción está definida, revisamos la fecha de corte:
    if (row[:FECHA_DEF] != "9999-99-99")

        #Si estamos en la fecha de corte o después, consideramos al paciente como fallecido.
        if Date(row[:FECHA_DEF]) <= fecha_corte

            return false
        end
    end

    #En otro caso, consideramos al paciente como vivo
    return true
end

#Definimos una función que devuelve los dataframes de interés.
#Estos contienen los datos filtrados entre el inicio de la epidemia y una fecha de corte.
function cargar_datos_fecha(datos, fecha_corte)

    #Filtramos los casos ingresados entre el inicio del brote y la fecha de corte.
    datos_corte = filter(row -> row[:FECHA_INGRESO] <= fecha_corte, datos)

    #Clasifiquemos los casos:
    #Positivos -> :CLASIFICACION_FINAL == 1,2,3 (positivo por laboratorio, dictaminación, asociación epidemiológica o prueba de antígeno)
    #Sospechosos -> :CLASIFICACION_FINAL == 6 (resultado pendiente)
    #Negativos -> :CLASIFICACION_FINAL == 7
    positivos = datos_corte[datos_corte.CLASIFICACION_FINAL .∈ [[1, 2, 3]], :]
    sospechosos = datos_corte[datos_corte.CLASIFICACION_FINAL .== 6, :]
    negativos = datos_corte[datos_corte.CLASIFICACION_FINAL .== 7, :]

    #Removemos los fallecidos, si su fallecimiento es anterior o igual a la fecha de corte:
    #Fallecidos -> :FECHA_DEF != "9999-99-99"
    fallecidos = filter(row -> !(clasificación_vivo(fecha_corte, row)), positivos)
    vivos = filter(row -> clasificación_vivo(fecha_corte, row), positivos)

    #Clasificamos a los pacientes vivos en ambulatorios y hospitalizados:
    #Ambulatorios -> :TIPO_PACIENTE == 1
    #Hospitalizados -> :TIPO_PACIENTE == 2
    ambulatorios = vivos[vivos.TIPO_PACIENTE .== 1, :]
    hospitalizados = vivos[vivos.TIPO_PACIENTE .== 2, :]

    #Clasificamos a los pacientes hospitalizados en leves, graves y críticos:
    #Leves -> :UCI == 2 && :INTUBADO == 2
    #Graves -> :UCI == 1 && :INTUBADO == 2 (En UCI, pero sin intubar)
    #Críticos -> :INTUBADO == 1 (Intubados)
    leves = filter(row -> (row[:UCI] == 2) && (row[:INTUBADO] == 2), hospitalizados)
    graves = filter(row -> (row[:UCI] == 1) && (row[:INTUBADO] == 2), hospitalizados)
    críticos = filter(row -> (row[:INTUBADO] == 1), hospitalizados)

    return negativos, sospechosos, positivos, fallecidos, vivos, ambulatorios, hospitalizados, leves, graves, críticos
end

#Definimos una función auxiliar para contar resultados por clave de estado:
#Tomaremos la entidad de la unidad de atención médica para identificar la entidad de la información.
número(clave_entidad, df) = length(filter(row -> row[:ENTIDAD_UM] == clave_entidad, df)[!, :ENTIDAD_UM])
número(clave_entidad) = df -> número(clave_entidad, df)

#Definimos una función auxiliar que junte los datos de un estado:
function cálculo_estado(clave_entidad, negativos, sospechosos, positivos, fallecidos, vivos, ambulatorios, hospitalizados, leves, graves, críticos)

    negativos_edo = número(clave_entidad)(negativos)
    sospechosos_edo = número(clave_entidad)(sospechosos)
    positivos_edo = número(clave_entidad)(positivos)

    fallecidos_edo = número(clave_entidad)(fallecidos)

    ambulatorios_edo = número(clave_entidad)(ambulatorios)
    hospitalizados_edo = número(clave_entidad)(hospitalizados)
    leves_edo = número(clave_entidad)(leves)
    graves_edo = número(clave_entidad)(graves)
    críticos_edo = número(clave_entidad)(críticos)

    return [negativos_edo, sospechosos_edo, positivos_edo, fallecidos_edo, ambulatorios_edo, hospitalizados_edo, leves_edo, graves_edo, críticos_edo]
end

#Definimos una función que realice los cálculos para todos los estados y el país, devolviendo un string de resultados listos para agregar al archivo de registro.
function información_fecha(datos, fecha)

    datos_acumulados = cargar_datos_fecha(datos, fecha)

    resumen_estados = [cálculo_estado(i, datos_acumulados...) for i in 1:32]
    resumen_país = sum(resumen_estados)

    fila = string.(vcat(resumen_estados..., resumen_país))

    #Agrega la fecha a la primer columna:
    fecha_string = string(fecha)
    pushfirst!(fila, fecha_string)

    #Agrega comas para el csv y lo junta todo en un string
    fila_csv = prod(fila[1:(end - 1)].*",")*fila[end]

    return fila_csv
end

#Definamos una función que itere sobre las fechas y genere la tabla resumen:
function tabla_resumen(datos, fecha_análisis; fecha_máxima = fecha_análisis, fecha_mínima = Date("2020-01-01"))

    #Construyamos el header del .csv:
    #Definamos las abreviaturas de las entidades en orden: claves 1, 2, 3,... 32.
    abreviaturas_entidades = ["AGU", "BCN", "BCS", "CAM", "COA", "COL", "CHP", "CHH", "CMX", "DUR", "GUA", "GRO", "HID", "JAL", "MEX", "MIC", "MOR", "NAY", "NLE", "OAX", "PUE", "QUE", "ROO", "SLP", "SIN", "SON", "TAB", "TAM", "TLA", "VER", "YUC", "ZAC", "TOT"] #Añadimos una categoría cumulativa

    #Y los tags de los casos negativos (_N), sospechosos(_S), positivos (_P), positivos fallecidos (_PF), positivos ambulatorios (_PA), positivos hospitalizados (_PH),
    # positivos hospitalizados leves (_PHL), positivos hospitalizados graves (_PHG) y positivos hospitalizados críticos (_PHC)
    tags = ["_N", "_S", "_P", "_PF", "_PA", "_PH", "_PHL", "_PHG", "_PHC"]
    nombres_columnas = [entidad*tag for entidad in abreviaturas_entidades for tag in tags]

    #Generemos el header
    header = "Fecha,"*prod(nombres_columnas[1:(end - 1)].*",")*nombres_columnas[end]

    fecha_archivo = Dates.format(fecha_análisis, "yyyymmdd")

    open("Mexico_COVID19_$(fecha_archivo).csv", "w") do io

        #Escribimos el header:
        write(io, header*"\n")

        #Hacemos el cálculo de cada día y lo agreamos al archivo:
        for fecha in fecha_mínima:Day(1):fecha_máxima

            fila_csv = información_fecha(datos, fecha)

            write(io, fila_csv*"\n")
        end
    end

    return "Done"
end

####
#Construyamos el archivo resumen:

#Cambiamos el directorio de trabajo a dónde se encuentran los datos.
cd("Open_data/COVID-19")

fecha_análisis = today()

#Los datos se encuentran en formato .csv al interior del archivo .zip:
datos_zip = ZipFile.Reader(Dates.format(fecha_análisis, "yyyymm")*"/"*Dates.format(fecha_análisis, "yyyymmdd")*".zip")
datos = CSV.read(datos_zip.files[1], header = 1, types = Dict(:FECHA_DEF => String), DataFrame)[: , [:FECHA_INGRESO, :ENTIDAD_UM, :CLASIFICACION_FINAL, :FECHA_DEF, :TIPO_PACIENTE, :UCI, :INTUBADO]]
sort!(datos, [:FECHA_INGRESO, :ENTIDAD_UM, :CLASIFICACION_FINAL, :FECHA_DEF, :TIPO_PACIENTE, :UCI, :INTUBADO])

tabla_resumen(datos, fecha_análisis)
