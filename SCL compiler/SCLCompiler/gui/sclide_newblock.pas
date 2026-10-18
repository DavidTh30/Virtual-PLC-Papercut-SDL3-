{ SCL Studio - "Add new block" dialog (OB / FB / FC / DB / UDT) }
unit sclide_newblock;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, StdCtrls, ExtCtrls, Spin, Dialogs, scl_ast;

type
  TNewBlockResult = record
    Kind: TUnitKind;
    Name: string;
    Number: Integer;      // 0 = automatic
    RetType: string;
    InstanceOf: string;
    Optimized: Boolean;
  end;

function ExecuteNewBlockDialog(const FBNames: TStrings; Classic: Boolean; out R: TNewBlockResult): Boolean;

implementation

type
  TNewBlockForm = class(TForm)
  public
    KindBox: TRadioGroup;
    NameEdit: TEdit;
    NumEdit: TSpinEdit;
    RetBox: TComboBox;
    InstBox: TComboBox;
    OptCheck: TCheckBox;
    RetLabel, InstLabel: TLabel;
    procedure KindChange(Sender: TObject);
    procedure OkClick(Sender: TObject);
  end;

procedure TNewBlockForm.KindChange(Sender: TObject);
begin
  RetBox.Enabled := KindBox.ItemIndex = 2;
  RetLabel.Enabled := RetBox.Enabled;
  InstBox.Enabled := KindBox.ItemIndex = 3;
  InstLabel.Enabled := InstBox.Enabled;
  NumEdit.Enabled := KindBox.ItemIndex <> 4;
  case KindBox.ItemIndex of
    0: if (NameEdit.Text = '') or (Pos('Block_', NameEdit.Text) = 1) then NameEdit.Text := 'Cyclic interrupt';
  end;
end;

procedure TNewBlockForm.OkClick(Sender: TObject);
var
  S: string;
  I: Integer;
begin
  S := Trim(NameEdit.Text);
  if S = '' then
  begin
    MessageDlg('Enter a block name', mtError, [mbOK], 0);
    Exit;
  end;
  for I := 1 to Length(S) do
    if S[I] in ['"', '''', '\', '/', ':', '*', '?', '<', '>', '|'] then
    begin
      MessageDlg('The name contains an invalid character: ' + S[I], mtError, [mbOK], 0);
      Exit;
    end;
  ModalResult := mrOk;
end;

function ExecuteNewBlockDialog(const FBNames: TStrings; Classic: Boolean; out R: TNewBlockResult): Boolean;
var
  F: TNewBlockForm;
  Y: Integer;
  B: TButton;
  L: TLabel;

  function Lbl(const C: string; AY: Integer): TLabel;
  begin
    Result := TLabel.Create(F);
    Result.Parent := F;
    Result.Caption := C;
    Result.Left := 200;
    Result.Top := AY + 4;
  end;

begin
  F := TNewBlockForm.CreateNew(nil);
  try
    F.Caption := 'Add new block';
    F.Position := poMainFormCenter;
    F.BorderStyle := bsDialog;
    F.Width := 560;
    F.Height := 300;
    F.KindBox := TRadioGroup.Create(F);
    with F.KindBox do
    begin
      Parent := F;
      Left := 10; Top := 10; Width := 170; Height := 200;
      Caption := 'Block type';
      Items.Add('Organization block (OB)');
      Items.Add('Function block (FB)');
      Items.Add('Function (FC)');
      Items.Add('Data block (DB)');
      Items.Add('PLC data type (UDT)');
      ItemIndex := 1;
      OnClick := @F.KindChange;
    end;
    Y := 14;
    Lbl('Name:', Y);
    F.NameEdit := TEdit.Create(F);
    F.NameEdit.Parent := F;
    F.NameEdit.SetBounds(300, Y, 240, 24);
    F.NameEdit.Text := 'Block_1';
    Inc(Y, 34);
    Lbl('Number (0 = auto):', Y);
    F.NumEdit := TSpinEdit.Create(F);
    F.NumEdit.Parent := F;
    F.NumEdit.SetBounds(300, Y, 100, 24);
    F.NumEdit.MinValue := 0;
    F.NumEdit.MaxValue := 65535;
    Inc(Y, 34);
    F.RetLabel := Lbl('FC return type:', Y);
    F.RetBox := TComboBox.Create(F);
    F.RetBox.Parent := F;
    F.RetBox.SetBounds(300, Y, 240, 24);
    F.RetBox.Items.CommaText := 'Void,Bool,Int,DInt,Real,LReal,Time,Word,DWord';
    F.RetBox.Text := 'Void';
    Inc(Y, 34);
    F.InstLabel := Lbl('DB type:', Y);
    F.InstBox := TComboBox.Create(F);
    F.InstBox.Parent := F;
    F.InstBox.SetBounds(300, Y, 240, 24);
    F.InstBox.Style := csDropDownList;
    F.InstBox.Items.Add('(global DB)');
    if FBNames <> nil then F.InstBox.Items.AddStrings(FBNames);
    F.InstBox.ItemIndex := 0;
    Inc(Y, 34);
    F.OptCheck := TCheckBox.Create(F);
    F.OptCheck.Parent := F;
    F.OptCheck.SetBounds(200, Y, 300, 24);
    F.OptCheck.Caption := 'Optimized block access';
    F.OptCheck.Checked := not Classic;
    F.OptCheck.Enabled := not Classic;
    Inc(Y, 34);
    L := TLabel.Create(F);
    L.Parent := F;
    L.SetBounds(200, Y, 340, 20);
    L.Caption := 'Language: SCL';
    B := TButton.Create(F);
    B.Parent := F;
    B.Caption := 'OK';
    B.Default := True;
    B.SetBounds(360, 225, 85, 30);
    B.OnClick := @F.OkClick;
    B := TButton.Create(F);
    B.Parent := F;
    B.Caption := 'Cancel';
    B.Cancel := True;
    B.ModalResult := mrCancel;
    B.SetBounds(455, 225, 85, 30);
    F.KindChange(nil);
    Result := F.ShowModal = mrOk;
    if Result then
    begin
      case F.KindBox.ItemIndex of
        0: R.Kind := ukOB;
        1: R.Kind := ukFB;
        2: R.Kind := ukFC;
        3: R.Kind := ukDB;
      else
        R.Kind := ukUDT;
      end;
      R.Name := Trim(F.NameEdit.Text);
      R.Number := F.NumEdit.Value;
      R.RetType := Trim(F.RetBox.Text);
      if F.InstBox.ItemIndex > 0 then R.InstanceOf := F.InstBox.Text else R.InstanceOf := '';
      R.Optimized := F.OptCheck.Checked;
    end;
  finally
    F.Free;
  end;
end;

end.
