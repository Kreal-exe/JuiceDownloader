namespace JuiceDownloader.ViewModels;

public interface IDialogService
{
    Task<bool> ConfirmAsync(string title, string body, string okText, bool danger);
    string? PickFolder(string? startIn);
}
