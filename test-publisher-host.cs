// Test host declines the genuine PowerShell publisher prompt as Enter does.
// Signature validation and policy enforcement remain PowerShell's own.
using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Globalization;
using System.Management.Automation;
using System.Management.Automation.Host;
using System.Security;

public sealed class PublisherRefusalHost : PSHost {
    private readonly PSHost parent;
    public readonly PublisherRefusalUI RefusalUI;
    public PublisherRefusalHost(PSHost host) {
        parent = host; RefusalUI = new PublisherRefusalUI(host.UI);
    }
    public override Guid InstanceId { get { return parent.InstanceId; } }
    public override string Name { get { return "Publisher refusal regression"; } }
    public override Version Version { get { return new Version(1, 0); } }
    public override CultureInfo CurrentCulture { get { return parent.CurrentCulture; } }
    public override CultureInfo CurrentUICulture { get { return parent.CurrentUICulture; } }
    public override PSHostUserInterface UI { get { return RefusalUI; } }
    public override void SetShouldExit(int code) { throw new InvalidOperationException("Unexpected exit " + code); }
    public override void EnterNestedPrompt() { throw new NotSupportedException(); }
    public override void ExitNestedPrompt() { throw new NotSupportedException(); }
    public override void NotifyBeginApplication() { parent.NotifyBeginApplication(); }
    public override void NotifyEndApplication() { parent.NotifyEndApplication(); }
}
public sealed class PublisherRefusalUI : PSHostUserInterface {
    private readonly PSHostUserInterface parent;
    public int Denials;
    public PublisherRefusalUI(PSHostUserInterface ui) { parent = ui; }
    public override PSHostRawUserInterface RawUI { get { return parent.RawUI; } }
    public override int PromptForChoice(string caption, string message, Collection<ChoiceDescription> choices, int defaultChoice) {
        if (!message.Contains("Microsoft.WinGet.Client") || !message.Contains("Format.ps1xml") ||
            defaultChoice < 0 || !choices[defaultChoice].Label.Replace("&", "").Equals("Do not run", StringComparison.OrdinalIgnoreCase)) {
            parent.WriteLine("TEST: unexpected prompt (not approved): " + message);
            throw new InvalidOperationException("Unexpected prompt: " + message);
        }
        Denials++;
        parent.WriteLine("TEST: genuine publisher prompt declined (default): " + message);
        return defaultChoice;
    }
    public override string ReadLine() { throw new NotSupportedException(); }
    public override SecureString ReadLineAsSecureString() { throw new NotSupportedException(); }
    public override Dictionary<string, PSObject> Prompt(string c, string m, Collection<FieldDescription> d) { throw new NotSupportedException(); }
    public override PSCredential PromptForCredential(string c, string m, string u, string t) { throw new NotSupportedException(); }
    public override PSCredential PromptForCredential(string c, string m, string u, string t, PSCredentialTypes a, PSCredentialUIOptions o) { throw new NotSupportedException(); }
    public override void Write(string v) { parent.Write(v); }
    public override void Write(ConsoleColor f, ConsoleColor b, string v) { parent.Write(f, b, v); }
    public override void WriteLine(string v) { parent.WriteLine(v); }
    public override void WriteErrorLine(string v) { parent.WriteErrorLine(v); }
    public override void WriteDebugLine(string v) { parent.WriteDebugLine(v); }
    public override void WriteProgress(long s, ProgressRecord r) { parent.WriteProgress(s, r); }
    public override void WriteVerboseLine(string v) { parent.WriteVerboseLine(v); }
    public override void WriteWarningLine(string v) { parent.WriteWarningLine(v); }
}
