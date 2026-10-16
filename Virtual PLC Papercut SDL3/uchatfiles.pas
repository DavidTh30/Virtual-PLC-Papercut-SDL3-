unit uChatFiles;

{ Files for the Claude chat.

  LoadChatFile   an attachment for a question: PNG / BMP / JPG (sent as PNG or JPEG, at most 1568
                 pixels on the long side and 3.75 MB, so the base64 stays under the 5 MB of an image
                 block), PDF (base64, up to 20 MB) or TXT (UTF-8; other encodings are converted, up
                 to 400 KB)
  ChatToText     the conversation as plain text (export TXT)
  (the PDF export is uChatPdf: real text and the pictures) }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, StrUtils, base64, BGRABitmap, BGRABitmapTypes, FPWriteJPEG, FPImage, LazUTF8,
  LConvEncoding, uClaude;

const
  MaxImageSide = 1568;
  MaxImageBytes = 3750000;
  MaxPdfBytes = 20 * 1024 * 1024;
  MaxTextBytes = 400 * 1024;
  ChatFileFilter = 'Images, PDF, text (*.png;*.bmp;*.jpg;*.jpeg;*.pdf;*.txt)|*.png;*.bmp;*.jpg;*.jpeg;*.pdf;*.txt|' +
    'All files (*.*)|*.*';

function LoadChatFile(const FileName: string; out A: TChatAttachment; out Err: string): Boolean;
function ChatToText(Agent: TClaudeAgent; const Title: string): string;
function JpegBytes(B: TBGRABitmap; Quality: Integer = 88): string;

implementation

function SizeOfFile(const FileName: string): Int64;
var
  R: TSearchRec;
begin
  Result := 0;
  if FindFirst(FileName, faAnyFile, R) = 0 then Result := R.Size;
  FindClose(R);
end;

function ReadAll(const FileName: string): string;
var
  F: TFileStream;
begin
  F := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(Result, F.Size);
    if F.Size > 0 then F.ReadBuffer(Result[1], F.Size);
  finally
    F.Free;
  end;
end;

function PngBytes(B: TBGRABitmap): string;
var
  M: TStringStream;
begin
  M := TStringStream.Create('');
  try
    B.SaveToStreamAsPng(M);
    Result := M.DataString;
  finally
    M.Free;
  end;
end;

function JpegBytes(B: TBGRABitmap; Quality: Integer): string;
var
  M: TStringStream;
  W: TFPWriterJPEG;
  Flat: TBGRABitmap;
begin
  // JPEG has no alpha: on white
  Flat := TBGRABitmap.Create(B.Width, B.Height, BGRAWhite);
  M := TStringStream.Create('');
  W := TFPWriterJPEG.Create;
  try
    Flat.PutImage(0, 0, B, dmDrawWithTransparency);
    W.CompressionQuality := Quality;
    Flat.SaveToStream(M, W);
    Result := M.DataString;
  finally
    W.Free;
    M.Free;
    Flat.Free;
  end;
end;

function LoadImage(const FileName, Ext: string; var A: TChatAttachment; out Err: string): Boolean;
var
  B, R: TBGRABitmap;
  Raw, Bytes: string;
  K: Single;
  Keep: Boolean;
begin
  Result := False;
  Raw := ReadAll(FileName);
  A.Bytes := Length(Raw);
  try
    B := TBGRABitmap.Create(FileName);
  except
    on E: Exception do
    begin
      Err := 'not a readable picture: ' + E.Message;
      Exit;
    end;
  end;
  try
    if (B.Width < 1) or (B.Height < 1) then
    begin
      Err := 'the picture is empty';
      Exit;
    end;
    // a PNG / JPEG that is small enough goes as it is (the real format, not the file name, decides)
    Keep := (Max(B.Width, B.Height) <= MaxImageSide) and (Length(Raw) <= MaxImageBytes);
    if Keep and (Copy(Raw, 1, 8) = #$89'PNG'#13#10#$1A#10) then
    begin
      A.Media := 'image/png';
      Bytes := Raw;
    end
    else if Keep and (Copy(Raw, 1, 3) = #$FF#$D8#$FF) then
    begin
      A.Media := 'image/jpeg';
      Bytes := Raw;
    end
    else
    begin
      if Max(B.Width, B.Height) > MaxImageSide then
      begin
        K := MaxImageSide / Max(B.Width, B.Height);
        R := B.Resample(Max(1, Round(B.Width * K)), Max(1, Round(B.Height * K)), rmFineResample) as TBGRABitmap;
        B.Free;
        B := R;
      end;
      if (Ext = '.jpg') or (Ext = '.jpeg') then
      begin
        A.Media := 'image/jpeg';
        Bytes := JpegBytes(B, 88);
      end
      else
      begin
        A.Media := 'image/png';
        Bytes := PngBytes(B);
        if Length(Bytes) > MaxImageBytes then
        begin
          A.Media := 'image/jpeg';
          Bytes := JpegBytes(B, 85);
        end;
      end;
      if Length(Bytes) > MaxImageBytes then
      begin
        A.Media := 'image/jpeg';
        Bytes := JpegBytes(B, 70);
      end;
    end;
    A.Kind := cfImage;
    A.Data := EncodeStringBase64(Bytes);
    Result := True;
  finally
    B.Free;
  end;
end;

function LoadChatFile(const FileName: string; out A: TChatAttachment; out Err: string): Boolean;
var
  Ext, S: string;
  Sz: Int64;
begin
  Result := False;
  Err := '';
  A := Default(TChatAttachment);
  A.Name := ExtractFileName(FileName);
  if not FileExists(FileName) then
  begin
    Err := 'the file does not exist';
    Exit;
  end;
  Ext := LowerCase(ExtractFileExt(FileName));
  try
    Sz := SizeOfFile(FileName);
    case Ext of
      '.png', '.bmp', '.jpg', '.jpeg':
        Result := LoadImage(FileName, Ext, A, Err);
      '.pdf':
        begin
          if Sz > MaxPdfBytes then
          begin
            Err := Format('the PDF is too big (%.1f MB, at most %d MB)', [Sz / 1048576, MaxPdfBytes div 1048576]);
            Exit;
          end;
          S := ReadAll(FileName);
          if Copy(S, 1, 5) <> '%PDF-' then
          begin
            Err := 'not a PDF file';
            Exit;
          end;
          A.Kind := cfPdf;
          A.Media := 'application/pdf';
          A.Bytes := Length(S);
          A.Data := EncodeStringBase64(S);
          Result := True;
        end;
      '.txt':
        begin
          if Sz > MaxTextBytes then
          begin
            Err := Format('the text is too big (%d KB, at most %d KB)', [Sz div 1024, MaxTextBytes div 1024]);
            Exit;
          end;
          S := ReadAll(FileName);
          A.Bytes := Length(S);
          if Copy(S, 1, 3) = #$EF#$BB#$BF then Delete(S, 1, 3)
          else if FindInvalidUTF8Codepoint(PChar(S), Length(S)) >= 0 then
            S := ConvertEncoding(S, GuessEncoding(S), EncodingUTF8);
          if Trim(S) = '' then
          begin
            Err := 'the text file is empty';
            Exit;
          end;
          A.Kind := cfText;
          A.Media := 'text/plain';
          A.Data := S;
          Result := True;
        end;
    else
      Err := 'only PNG, BMP, JPG, PDF and TXT files can be attached';
    end;
  except
    on E: Exception do
    begin
      Err := E.Message;
      Result := False;
    end;
  end;
end;

function ChatToText(Agent: TClaudeAgent; const Title: string): string;
var
  SL: TStringList;
  I: Integer;
  E: TChatEntry;
begin
  SL := TStringList.Create;
  try
    SL.Add(Title);
    SL.Add(StringOfChar('=', Max(10, UTF8Length(Title))));
    SL.Add('');
    for I := 0 to High(Agent.Chat) do
    begin
      E := Agent.Chat[I];
      case E.Kind of
        ckUser:
          begin
            SL.Add('You:');
            if E.Files <> '' then SL.Add('[attached: ' + StringReplace(E.Files, LineEnding, '; ', [rfReplaceAll]) + ']');
            SL.Add(E.Text);
            SL.Add('');
          end;
        ckTool: SL.Add('  -> ' + E.Text);
        ckInfo: begin SL.Add('(' + E.Text + ')'); SL.Add(''); end;
        ckError: begin SL.Add('Error: ' + E.Text); SL.Add(''); end;
      else
        begin
          if (I > 0) and (Agent.Chat[I - 1].Kind = ckTool) then SL.Add('');
          SL.Add('Claude:');
          SL.Add(E.Text);
          SL.Add('');
        end;
      end;
    end;
    SL.Add(Format('tokens: %d in, %d out', [Agent.InTokens, Agent.OutTokens]));
    Result := SL.Text;
  finally
    SL.Free;
  end;
end;

end.
