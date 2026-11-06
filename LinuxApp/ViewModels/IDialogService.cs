namespace JuiceDownloader.ViewModels;

public interface IDialogService
{
    Task<bool> ConfirmAsync(string title, string body, string okText, bool danger);
    Task<string?> PickFolderAsync(string title);
    Task CopyTextAsync(string text);
}
