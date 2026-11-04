import RemoteKeyboardCore
import SwiftUI

/// 「使用教學」: how to type and use the trackpad. The facts follow the manual (chapters 06 and 07).
struct TutorialView: View {
    var body: some View {
        List {
            Section("開始使用") {
                Text("先完成首頁「設定進度」的三項。")
                Text("1 在任一個輸入框點一下，叫出鍵盤。可以使用「測試輸入」。\n2 按住鍵盤左下角的地球鍵，選 Remote Keyboard。連按地球鍵也可以依序切換鍵盤。")
                Text("成功時，鍵盤上方出現「本機」與「遠端」切換。選了「遠端」並已連上 Mac 時，中間顯示綠色的「已連接」。")
                picture("kb-connected", "Remote Keyboard 的英文頁面，頂部左側為本機與遠端切換，遠端已選取，中間顯示已連接")
            }
            Section("本機與遠端") {
                Text("本機：直接輸入到 iPhone 目前的 App，不傳到 Mac。")
                Text("遠端：經藍牙加密傳到已配對的 Mac，輸入到 Mac 目前的欄位。")
                Text("選「本機」時，頂部只剩切換與收起鍵盤，沒有狀態文字、觸控板與即時、草稿。")
            }
            Section("即時與草稿") {
                Text("即時：每按一個鍵，文字立刻出現在 Mac。適合一般打字。")
                Text("草稿：先在鍵盤上方的草稿列編輯，按「傳送」才一次送到 Mac。適合想先檢查或修改再送出。")
                Text("草稿列的左右箭頭鍵把游標左移或右移一格。點一下草稿文字，游標移到手指的位置；按住手指左右拖曳，游標連續移動。傳送會把草稿送到 Mac，並清空草稿列。")
                picture("kb-remoteDraft", "遠端、草稿模式：頂部下方有草稿列，左側是左右箭頭鍵，中間是草稿文字，右側是傳送按鈕")
            }
            Section("輸入方式") {
                Text("英文：預設頁面。大寫鍵有三種狀態：關閉、下一個字母大寫、鎖定大寫。刪除鍵按住會連續刪除。")
                Text("符號：按左下方的「符號」進入數字與符號頁，按左側的「#+=」切換符號層，按「ABC」回到英文字母頁。")
                Text("手寫：需要先在「中文輸入與手寫」下載手寫模型，並開啟「允許完整取用」，沒有完整取用時中文頁會改用速成。在書寫區寫一個字，點選上方候選字輸入，寫錯時按「重寫」。")
                picture("kb-handwriting", "手寫頁：書寫區寫著香港，上方是候選字列，底部有符號、中英、空白、重寫與換行")
                Text("速成：字母位置和英文頁相同，主字是字根，右上角的小字是英文字母。輸入碼顯示在候選列最左邊，點選候選字輸入，按「空白」可以直接輸入第一個候選字。")
                Text("按「中英」切換中文與英文。")
            }
            Section("觸控板手勢") {
                Text("使用前：已配對，鍵盤在「遠端」模式且顯示「已連接」，Mac 面板的「允許觸控板控制」已勾選。按頂部列的「觸控板」開啟，按「鍵盤」回到打字。")
                picture("kb-trackpad", "觸控板頁：頂部列顯示已連接，下方是一整片灰色的觸控板")
                Text("移動：一根手指在觸控板上滑動。")
                Text("點按：一根手指快速輕點一下是左鍵單擊，快速連續輕點兩下是雙擊。")
                Text("雙擊後按住拖曳：輕點一下，馬上再用同一根手指按下並按住，然後移動；放開手指就放開拖曳。")
                Text("右鍵：兩根手指同時快速輕點一下。")
                Text("捲動：兩根手指一起上下左右滑動。")
            }
            Section("密碼保護") {
                Text("Mac 在密碼欄、開啟安全輸入或螢幕鎖定時，Receiver 不會輸入文字，鍵盤顯示「密碼不能輸入」。即時模式打的字不會送出；草稿模式的文字與換行會被丟棄，傳送會被 Mac 拒絕。")
                Text("這項保護只涵蓋系統標示為密碼欄的欄位，請不要用這個鍵盤輸入密碼。")
            }
            Section {
                if let url = URL(string: AppAbout.manualURL) {
                    Link("看完整手冊", destination: url)
                        .accessibilityIdentifier("rk.tutorial.manual")
                }
            }
        }
        .navigationTitle("使用教學")
    }

    private func picture(_ name: String, _ label: String) -> some View {
        Image(name)
            .resizable()
            .scaledToFit()
            .frame(maxHeight: 240)
            .frame(maxWidth: .infinity)
            .accessibilityLabel(label)
    }
}
