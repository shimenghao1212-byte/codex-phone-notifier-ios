import Foundation

@main
struct SpeechTextRegression {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool) {
        precondition(condition(), "Speech cleanup regression failed at check \(checks + 1)")
        checks += 1
    }
    static func main() {
        // Exact counterparts of windows/test_speech_text.py parity samples.
        let samples: [(String, String)] = [
            ("已修复 Codex、Python、GitHub 和 API，iPhone 正常。", "已修复 Codex、Python、GitHub 和 API，iPhone 正常。"),
            ("Codex/GitHub/API/USB，版本 1.8.1，日期 2026-09-08，-42，2+3=5。", "Codex/GitHub/API/USB，版本 1.8.1，日期 2026-09-08，-42，2+3=5。"),
            ("2**3**4，x**y**z，__identifier__，__init__。", "2**3**4，x**y**z，__identifier__，__init__。"),
            ("结果**检查通过**，并且__已经保存__。", "结果检查通过，并且已经保存。"),
            ("通知/来电，男/女声，开启/关闭。", "通知/来电，男/女声，开启/关闭。"),
            ("6 /3=2，6 /-3=-2，6 /−3=-2，6 /x=2，6 /x。", "6 /3=2，6 /-3=-2，6 /−3=-2，6 /x=2，6 /x。"),
            ("保留 /选项，路径 /tmp/result.txt，路径 \"/tmp\"。", "保留 /选项，路径 文件路径，路径 文件路径。"),
            ("温度 -2.5，进度 5%，日期 2026-09-08，6/3=2，2*3=6，2**3=8。", "温度 -2.5，进度 5%，日期 2026-09-08，6/3=2，2*3=6，2**3=8。"),
            ("打开 [安装包](<D:/My Files/App.ipa>)，参考 [官网](https://example.com/a?q=1)。", "打开 安装包，参考 官网。"),
            ("访问 https://example.com/a?token=abcdef123456。完成！", "访问 链接。完成！"),
            ("链接 https://example.com，已完成。", "链接 链接，已完成。"),
            ("D:\\项目\\out.png，已保存。", "文件路径，已保存。"),
            ("[发布说明](https://example.com/release(1).html)，[App.ipa](</D:/My Files/App.ipa>)。", "发布说明，App.ipa。"),
            ("See <https://example.com/a> or https://example.com/b.", "See 链接 or 链接."),
            ("保存在 D:/Programs/App/result.txt，或 /tmp/result.txt。", "保存在 文件路径，或 文件路径。"),
            ("文件 \"D:\\My Files\\报告.txt\"，文件名 result.txt 不变。", "文件 文件路径，文件名 result.txt 不变。"),
            ("共享 \\\\server\\share\\result.txt，目录 /Users/name。", "共享 文件路径，目录 文件路径。"),
            ("编号 550e8400-e29b-41d4-a716-446655440000。", "编号 标识符。"),
            ("SHA256 a6c5b93a4dd0a60585874150bb96950497582e5b53a0ef39e682132d199e20a5。", "SHA256 标识符。"),
            ("数字 1234567890123456789012345678901234567890 不变。", "数字 1234567890123456789012345678901234567890 不变。"),
            ("完成。\n```json\n{\"id\":\"abc\", \"code\":123}\n```\n接下来检查。", "完成。\n代码请在电脑查看。\n接下来检查。"),
            ("说明。\n~~~python\nprint(1)\n~~~~\n结束。", "说明。\n代码请在电脑查看。\n结束。"),
            ("说明。\n```python\nprint(1)", "说明。\n代码请在电脑查看。"),
            ("## 结果\n**检查通过**，`API` 保留。", "结果\n检查通过，API 保留。"),
            // Already-flattened code stays readable; only recognized tokens shorten.
            ("{\"result\":true,\"id\":\"550e8400-e29b-41d4-a716-446655440000\"}", "{\"result\":true,\"id\":\"标识符\"}"),
            ("{\"ok\":true,\"data\":{\"url\":\"https://example.com/a\",\"path\":\"D:/App/out.png\"}}，API 通过。", "{\"ok\":true,\"data\":{\"url\":\"链接\",\"path\":文件路径}}，API 通过。"),
            ("", "")
        ]
        for (original, expected) in samples {
            check(SpeechText.clean(original) == expected)
            check(SpeechText.clean(expected) == expected)
        }
        let large = SpeechText.clean(String(repeating: "🙂", count: SpeechText.maximumInputBytes / 4 + 10))
        check(!large.contains("\u{fffd}"))
        check(large.hasSuffix("内容较长，剩余内容请查看电脑。"))
        check(large.utf8.count < SpeechText.maximumInputBytes + 100)
        let malformed = String(repeating: "[", count: 10000) + "检查 API 成功。"
        check(SpeechText.clean(malformed) == malformed)
        check(SpeechText.clean("普通 550e8400-e29b 是前缀，不是完整标识。") == "普通 550e8400-e29b 是前缀，不是完整标识。")
        print("Speech cleanup regression passed: \(checks) checks")
    }
}
