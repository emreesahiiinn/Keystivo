import Foundation

/// Natural-language unit conversion: "10 km to mi", "72 f in c", "5 GB in MiB",
/// "3,5 kg kaç lb", "100 km/h in mph". Works offline with Foundation units.
nonisolated public enum UnitConverter {
    public struct Conversion: Equatable, Sendable {
        public let value: Double
        public let fromSymbol: String
        public let result: Double
        public let toSymbol: String
    }

    /// Words that separate the source and target unit, across supported languages.
    static let connectors: Set<String> = [
        "to", "in", "into", "as", "->", "→", "=", ">", "kaç", "kac", "nach", "zu", "en", "vers",
        "a", "em", "para", "в", "во", "到", "转", "换成", "は", "を", "로", "으로", "in?",
    ]

    public static func convert(_ input: String) -> Conversion? {
        let normalized = input.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "?", with: "")
        let words = tokenize(normalized)
        guard words.count >= 3 else { return nil }
        guard let value = Calculator.parseNumber(words[0]) ?? Double(words[0]) else { return nil }

        // Find the connector; everything between number and connector is the source unit.
        guard let connectorIndex = words.indices.dropFirst(2).first(where: { connectors.contains(words[$0].lowercased()) }) else {
            // "10 km mi" (no connector): exactly three words.
            guard words.count == 3, let from = unit(named: words[1]), let to = unit(named: words[2]) else { return nil }
            return convert(value, from: from, to: to)
        }
        let fromName = words[1..<connectorIndex].joined(separator: " ")
        let toName = words[(connectorIndex + 1)...].joined(separator: " ")
        guard let from = unit(named: fromName), let to = unit(named: toName) else { return nil }
        return convert(value, from: from, to: to)
    }

    static func convert(_ value: Double, from: (Dimension, String), to: (Dimension, String)) -> Conversion? {
        guard type(of: from.0) == type(of: to.0) else { return nil }
        let measurement = Measurement(value: value, unit: from.0)
        let result = measurement.converted(to: to.0).value
        return Conversion(value: value, fromSymbol: from.1, result: result, toSymbol: to.1)
    }

    /// Splits "10km" into ["10", "km"] and keeps multi-character connectors intact.
    static func tokenize(_ input: String) -> [String] {
        var tokens: [String] = []
        for raw in input.split(separator: " ") {
            let word = String(raw)
            if let firstLetter = word.firstIndex(where: { !($0.isNumber || $0 == "." || $0 == "," || $0 == "-" ) }),
               firstLetter != word.startIndex, word[word.startIndex].isNumber || word[word.startIndex] == "-" {
                tokens.append(String(word[..<firstLetter]))
                tokens.append(String(word[firstLetter...]))
            } else {
                tokens.append(word)
            }
        }
        return tokens
    }

    static func unit(named rawName: String) -> (Dimension, String)? {
        let name = rawName.trimmingCharacters(in: .whitespaces)
        if let unit = caseSensitive[name] { return unit }
        return table[name.lowercased()]
    }

    /// Case matters for data units (Mb vs MB) and a few symbols.
    static let caseSensitive: [String: (Dimension, String)] = [
        "B": (UnitInformationStorage.bytes, "B"), "kB": (UnitInformationStorage.kilobytes, "kB"),
        "KB": (UnitInformationStorage.kilobytes, "KB"), "MB": (UnitInformationStorage.megabytes, "MB"),
        "GB": (UnitInformationStorage.gigabytes, "GB"), "TB": (UnitInformationStorage.terabytes, "TB"),
        "PB": (UnitInformationStorage.petabytes, "PB"), "Kb": (UnitInformationStorage.kilobits, "Kb"),
        "Mb": (UnitInformationStorage.megabits, "Mb"), "Gb": (UnitInformationStorage.gigabits, "Gb"),
        "KiB": (UnitInformationStorage.kibibytes, "KiB"), "MiB": (UnitInformationStorage.mebibytes, "MiB"),
        "GiB": (UnitInformationStorage.gibibytes, "GiB"), "TiB": (UnitInformationStorage.tebibytes, "TiB"),
    ]

    static let table: [String: (Dimension, String)] = {
        var map: [String: (Dimension, String)] = [:]
        func add(_ unit: Dimension, _ symbol: String, _ names: [String]) {
            for name in names { map[name] = (unit, symbol) }
        }
        // Length
        add(UnitLength.millimeters, "mm", ["mm", "millimeter", "millimeters", "milimetre", "milimetre"])
        add(UnitLength.centimeters, "cm", ["cm", "centimeter", "centimeters", "santim", "santimetre"])
        add(UnitLength.meters, "m", ["m", "meter", "meters", "metre", "metres", "metre", "metro", "metros", "米"])
        add(UnitLength.kilometers, "km", ["km", "kilometer", "kilometers", "kilometre", "kilometres", "kilometro", "公里", "キロ"])
        add(UnitLength.inches, "in", ["inch", "inches", "\"", "inç", "zoll", "pouce", "pulgada", "pollice", "英寸"])
        add(UnitLength.feet, "ft", ["ft", "foot", "feet", "fit", "fuß", "pied", "pie", "piede", "英尺"])
        add(UnitLength.yards, "yd", ["yd", "yard", "yards", "yarda"])
        add(UnitLength.miles, "mi", ["mi", "mile", "miles", "mil", "meile", "meilen", "mille", "milla", "miglio", "英里", "マイル"])
        add(UnitLength.nauticalMiles, "nmi", ["nmi", "nautical mile", "nautical miles", "deniz mili"])
        // Mass
        add(UnitMass.milligrams, "mg", ["mg", "milligram", "milligrams", "miligram"])
        add(UnitMass.grams, "g", ["g", "gram", "grams", "gramm", "gramme", "gramo", "grammo", "克"])
        add(UnitMass.kilograms, "kg", ["kg", "kilo", "kilos", "kilogram", "kilograms", "kilogramm", "公斤", "キログラム"])
        add(UnitMass.metricTons, "t", ["t", "ton", "tons", "tonne", "tonnes", "tonelada"])
        add(UnitMass.ounces, "oz", ["oz", "ounce", "ounces", "ons", "unze", "once", "onza"])
        add(UnitMass.pounds, "lb", ["lb", "lbs", "pound", "pounds", "libre", "pfund", "livre", "libra", "磅"])
        add(UnitMass.stones, "st", ["st", "stone", "stones"])
        // Temperature
        add(UnitTemperature.celsius, "°C", ["c", "°c", "celsius", "santigrat", "derece", "摄氏度"])
        add(UnitTemperature.fahrenheit, "°F", ["f", "°f", "fahrenheit", "华氏度"])
        add(UnitTemperature.kelvin, "K", ["k", "kelvin"])
        // Volume
        add(UnitVolume.milliliters, "ml", ["ml", "milliliter", "milliliters", "mililitre"])
        add(UnitVolume.centiliters, "cl", ["cl", "centiliter"])
        add(UnitVolume.deciliters, "dl", ["dl", "deciliter"])
        add(UnitVolume.liters, "l", ["l", "liter", "liters", "litre", "litres", "litro", "litros", "升"])
        add(UnitVolume.cubicMeters, "m³", ["m3", "m³", "cubic meter", "metreküp"])
        add(UnitVolume.gallons, "gal", ["gal", "gallon", "gallons", "galon", "gallone"])
        add(UnitVolume.quarts, "qt", ["qt", "quart", "quarts"])
        add(UnitVolume.pints, "pt", ["pt", "pint", "pints"])
        add(UnitVolume.cups, "cup", ["cup", "cups", "bardak", "tasse"])
        add(UnitVolume.fluidOunces, "fl oz", ["floz", "fl oz", "fluid ounce", "fluid ounces"])
        add(UnitVolume.tablespoons, "tbsp", ["tbsp", "tablespoon", "tablespoons", "yemek kaşığı"])
        add(UnitVolume.teaspoons, "tsp", ["tsp", "teaspoon", "teaspoons", "çay kaşığı"])
        // Area
        add(UnitArea.squareMeters, "m²", ["m2", "m²", "sqm", "square meter", "square meters", "metrekare"])
        add(UnitArea.squareKilometers, "km²", ["km2", "km²", "square kilometer", "kilometrekare"])
        add(UnitArea.squareFeet, "ft²", ["ft2", "ft²", "sqft", "square foot", "square feet"])
        add(UnitArea.hectares, "ha", ["ha", "hectare", "hectares", "hektar"])
        add(UnitArea.acres, "ac", ["acre", "acres", "ac", "dönüm"])
        // Speed
        add(UnitSpeed.kilometersPerHour, "km/h", ["km/h", "kmh", "kph", "km/sa", "kmph"])
        add(UnitSpeed.milesPerHour, "mph", ["mph", "mi/h"])
        add(UnitSpeed.metersPerSecond, "m/s", ["m/s", "mps"])
        add(UnitSpeed.knots, "kn", ["kn", "knot", "knots", "kt", "knoten", "nœud", "nudo", "knot"])
        // Data (case-insensitive fallbacks favour bytes)
        add(UnitInformationStorage.bits, "bit", ["bit", "bits"])
        add(UnitInformationStorage.bytes, "B", ["b", "byte", "bytes", "bayt"])
        add(UnitInformationStorage.kilobytes, "kB", ["kb", "kilobyte", "kilobytes"])
        add(UnitInformationStorage.megabytes, "MB", ["mb", "megabyte", "megabytes"])
        add(UnitInformationStorage.gigabytes, "GB", ["gb", "gigabyte", "gigabytes"])
        add(UnitInformationStorage.terabytes, "TB", ["tb", "terabyte", "terabytes"])
        add(UnitInformationStorage.kibibytes, "KiB", ["kib", "kibibyte"])
        add(UnitInformationStorage.mebibytes, "MiB", ["mib", "mebibyte"])
        add(UnitInformationStorage.gibibytes, "GiB", ["gib", "gibibyte"])
        add(UnitInformationStorage.megabits, "Mb", ["mbit", "mbps", "megabit", "megabits"])
        add(UnitInformationStorage.gigabits, "Gb", ["gbit", "gbps", "gigabit", "gigabits"])
        // Time
        add(UnitDuration.milliseconds, "ms", ["ms", "millisecond", "milliseconds", "milisaniye"])
        add(UnitDuration.seconds, "s", ["s", "sec", "secs", "second", "seconds", "saniye", "sekunde", "seconde", "segundo", "secondo", "秒"])
        add(UnitDuration.minutes, "min", ["min", "mins", "minute", "minutes", "dakika", "dk", "minuten", "minuto", "minutos", "分钟", "分"])
        add(UnitDuration.hours, "h", ["h", "hr", "hrs", "hour", "hours", "saat", "stunde", "stunden", "heure", "heures", "hora", "horas", "ora", "ore", "小时", "時間"])
        add(UnitDuration(symbol: "d", converter: UnitConverterLinear(coefficient: 86_400)), "d", ["d", "day", "days", "gün", "gun", "tag", "tage", "jour", "jours", "día", "días", "giorno", "giorni", "天", "日"])
        add(UnitDuration(symbol: "wk", converter: UnitConverterLinear(coefficient: 604_800)), "wk", ["wk", "week", "weeks", "hafta", "woche", "wochen", "semaine", "semana", "settimana", "周"])
        // Energy
        add(UnitEnergy.joules, "J", ["j", "joule", "joules"])
        add(UnitEnergy.kilojoules, "kJ", ["kj", "kilojoule", "kilojoules"])
        add(UnitEnergy.calories, "cal", ["cal", "calorie", "calories", "kalori"])
        add(UnitEnergy.kilocalories, "kcal", ["kcal", "kilocalorie", "kilocalories", "kilokalori"])
        add(UnitEnergy.kilowattHours, "kWh", ["kwh", "kilowatt hour", "kilowatt hours"])
        // Pressure
        add(UnitPressure.newtonsPerMetersSquared, "Pa", ["pa", "pascal"])
        add(UnitPressure.kilopascals, "kPa", ["kpa", "kilopascal"])
        add(UnitPressure.bars, "bar", ["bar", "bars"])
        add(UnitPressure.poundsForcePerSquareInch, "psi", ["psi"])
        add(UnitPressure.millimetersOfMercury, "mmHg", ["mmhg"])
        // Angle
        add(UnitAngle.degrees, "°", ["deg", "degree", "degrees", "°"])
        add(UnitAngle.radians, "rad", ["rad", "radian", "radians", "radyan"])
        return map
    }()

    /// Units known to the converter's week/day aliases include "d", which would
    /// otherwise shadow nothing; nautical miles etc. are covered above.
    public static var supportedUnitCount: Int { table.count + caseSensitive.count }
}
