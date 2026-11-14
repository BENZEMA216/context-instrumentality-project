import Foundation

let folder = URL(string: "https://drive.google.com/drive/folders/synthetic-library")!
let both = AgentOnboardingStatement.make(googleDriveURL: folder, iCloudFolderName: "录音")
precondition(both.contains(folder.absoluteString))
precondition(both.contains("iCloud Drive 文件夹名称：录音"))
let noCloud = AgentOnboardingStatement.text
precondition(noCloud.contains("尚无可提供的云盘位置"))
precondition(!noCloud.contains("https://"))
let emptyName = AgentOnboardingStatement.make(iCloudFolderName: "  ")
precondition(emptyName == noCloud)

let googleOnly = AgentOnboardingStatement.make(
    googleDriveURL: folder, iCloudFolderName: "另一云盘录音", selectedCloud: .googleDrive)
precondition(googleOnly.contains(folder.absoluteString) && googleOnly.contains(".manifest.json"))
precondition(googleOnly.contains("旧文件名前缀是片段 ID"))
precondition(!googleOnly.contains("iCloud Drive") && !googleOnly.contains("另一云盘录音"))
let iCloudOnly = AgentOnboardingStatement.make(
    googleDriveURL: folder, iCloudFolderName: " 录音 ", selectedCloud: .iCloudDrive)
precondition(iCloudOnly.contains("文件夹名称： 录音 \n") && iCloudOnly.contains("commits/"))
precondition(iCloudOnly.contains("新音频按录音组存放"))
precondition(!iCloudOnly.contains("Google Drive") && !iCloudOnly.contains(folder.absoluteString))

let googleWithoutLink = AgentOnboardingStatement.make(iCloudFolderName: "另一云盘录音", selectedCloud: .googleDrive)
precondition(googleWithoutLink.contains("请向我确认文件夹链接") && !googleWithoutLink.contains("另一云盘录音"))
let iCloudWithoutName = AgentOnboardingStatement.make(googleDriveURL: folder, iCloudFolderName: "  ", selectedCloud: .iCloudDrive)
precondition(iCloudWithoutName.contains("请向我确认文件夹位置") && !iCloudWithoutName.contains(folder.absoluteString))

for statement in [googleOnly, iCloudOnly] {
    precondition(statement.contains("有哪些下一步你能帮我完成"))
    precondition(statement.contains("与当前请求有关"))
    precondition(statement.contains("确认服务及上传范围"))
    precondition(statement.contains("recordingGroup.id") && statement.contains("sessionID"))
}
print("Agent connection guide: provider isolation, missing locations and common guidance passed.")
