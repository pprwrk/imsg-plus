import IMsgCore

func pluralSuffix(for count: Int) -> String {
  count == 1 ? "" : "s"
}

func displayName(for meta: AttachmentMeta) -> String {
  if !meta.transferName.isEmpty { return meta.transferName }
  if !meta.filename.isEmpty { return meta.filename }
  return "(unknown)"
}
