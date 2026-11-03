import Foundation
import XCTest
@testable import patternlock

final class LocalizationTests: XCTestCase {
    private let languages = ["en", "ko", "ja", "fr", "de", "it", "zh-Hans"]

    private func bundle(for language: String) throws -> Bundle {
        let path = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"))
        return try XCTUnwrap(Bundle(path: path))
    }

    func testCompiledTranslationsAndPermissionPromptsAreBundled() throws {
        let expected = ["Vault settings", "보관함 설정", "保管庫の設定", "Réglages du coffre", "Tresoreinstellungen", "Impostazioni cassaforte", "保险库设置"]
        for (language, title) in zip(languages, expected) {
            let bundle = try bundle(for: language)
            XCTAssertEqual(String(localized: "Vault settings", bundle: bundle), title, language)
            for key in ["NSFaceIDUsageDescription", "NSPhotoLibraryUsageDescription", "NSPhotoLibraryAddUsageDescription"] {
                let prompt = bundle.localizedString(forKey: key, value: nil, table: "InfoPlist")
                XCTAssertNotEqual(prompt, key, "\(language): \(key)")
                XCTAssertFalse(prompt.isEmpty)
                if language != "en" {
                    let english = try self.bundle(for: "en").localizedString(forKey: key, value: nil, table: "InfoPlist")
                    XCTAssertNotEqual(prompt, english, "\(language): \(key)")
                }
            }
        }
    }

    func testCompiledPluralRulesForZeroOneAndMany() throws {
        let expected = [
            "en": ["0 items", "1 item", "2 items"],
            "ko": ["0개 항목", "1개 항목", "2개 항목"],
            "ja": ["0件", "1件", "2件"],
            "fr": ["0 élément", "1 élément", "2 éléments"],
            "de": ["0 Objekte", "1 Objekt", "2 Objekte"],
            "it": ["0 elementi", "1 elemento", "2 elementi"],
            "zh-Hans": ["0 个项目", "1 个项目", "2 个项目"]
        ]
        for language in languages {
            let bundle = try bundle(for: language)
            for count in 0...2 {
                let value = String(localized: "\(count) items", bundle: bundle, locale: Locale(identifier: language))
                XCTAssertEqual(value, expected[language]?[count], "\(language), count \(count)")
            }
        }
        for (language, expected) in [("en", "Delete 1 item?"), ("fr", "Supprimer 1 élément ?"), ("de", "1 Objekt löschen?"), ("it", "Eliminare 1 elemento?")] {
            let count = 1
            XCTAssertEqual(String(localized: "Delete \(count) items?", bundle: try bundle(for: language), locale: Locale(identifier: language)), expected)
        }
    }

    func testInterpolationCanReorderArgumentsAndPreservesUserNames() throws {
        let index = 2, total = 7
        for (language, expected) in [("ko", "7개 중 2번째"), ("ja", "7件中2件目"), ("fr", "2 sur 7"), ("de", "2 von 7"), ("it", "2 di 7"), ("zh-Hans", "第 2 项，共 7 项")] {
            let bundle = try bundle(for: language)
            XCTAssertEqual(String(localized: "\(index) of \(total)", bundle: bundle), expected)
            let name = "Personal · 100% · %@ · 家族"
            let prompt = String(localized: "Confirm the pattern for “\(name)”", bundle: bundle)
            XCTAssertTrue(prompt.contains(name), "User-entered names must remain verbatim: \(language)")
        }
    }
}
