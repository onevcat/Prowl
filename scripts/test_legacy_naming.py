import unittest

from check_legacy_naming import violations


class LegacyNamingTests(unittest.TestCase):
    def test_rejects_the_legacy_project_name(self):
        for text in (
            "@testable import supacode",
            "xcodebuild -scheme supacode",
            "supacode/Features/App/AppFeature.swift",
            "-only-testing:supacodeTests/FooTests",
            "let paths = SupacodePaths.baseDirectory",
            "private let logger = SupaLogger(\"App\")",
            "~/Library/Caches/supacode-spm-cache",
            "https://github.com/onevcat/supacode/issues/new",
        ):
            with self.subTest(text=text):
                self.assertEqual(violations(text), [1])

    def test_allows_uses_that_must_keep_the_old_name(self):
        for text in (
            "never the upstream `supabitapp/supacode`",
            "A personal fork of [Supacode](https://github.com/supabitapp/supacode)",
            'case prowlClassic = "supacodeClassic"',
            "Legacy `~/.supacode` is migrated to `~/.prowl` on first launch.",
            '.appending(path: "supacode.onevcat.json", directoryHint: .notDirectory)',
            "# APPLE_NOTARY_KEYCHAIN_PROFILE=supacode-notary",
            'host: "github.com", owner: "supabitapp", repo: "supacode")',
            "The old name `supacode` stays only for stored data.",
            "Numbered entries before 074 use the old paths (`supacode/...`).",
        ):
            with self.subTest(text=text):
                self.assertEqual(violations(text), [])

    def test_reports_the_line_number_and_checks_the_rest_of_an_allowed_line(self):
        self.assertEqual(violations("fine\nimport supacode\nfine"), [2])
        self.assertEqual(violations("`~/.supacode` and supacode/Support"), [1])


if __name__ == "__main__":
    unittest.main()
