### R/build_eml.R
#
# Builds a GBIF/OBIS-profile EML (Ecological Metadata Language) XML
# document describing the DATASET itself - creators, abstract, methods,
# license, project info. This is what IPT calls eml.xml, separate from
# the occurrence/event data files - IPT lets you import one directly
# instead of retyping everything into its metadata screens.
#
# Structure and element order follow a real, previously-accepted
# eml.xml the user provided as a sample (GBIF EML profile 1.3,
# eml-2.2.0 namespace) - matched precisely rather than guessed, since
# EML validators are strict about element order (XML Schema sequence).
# The generated document is parsed with xml2::read_xml() before being
# returned, so a structural mistake fails loudly here rather than
# shipping broken XML in the archive.

xml_escape <- function(x) {
  if (is.null(x) || length(x) == 0 || is.na(x) || x == "") return("")
  x <- gsub("&", "&amp;", x, fixed = TRUE)
  x <- gsub("<", "&lt;", x, fixed = TRUE)
  x <- gsub(">", "&gt;", x, fixed = TRUE)
  x <- gsub('"', "&quot;", x, fixed = TRUE)
  x <- gsub("'", "&apos;", x, fixed = TRUE)
  x
}

# Renders a person block (creator / metadataProvider / contact /
# associatedParty). `role` is only meaningful for associatedParty.
person_xml <- function(tag, person, role = NULL) {
  paste0(
    "\t\t<", tag, ">\n",
    "\t\t\t<individualName>\n",
    "\t\t\t\t<givenName>", xml_escape(person$given_name), "</givenName>\n",
    "\t\t\t\t<surName>", xml_escape(person$sur_name), "</surName>\n",
    "\t\t\t</individualName>\n",
    if (nzchar(xml_escape(person$organization))) paste0("\t\t\t<organizationName>", xml_escape(person$organization), "</organizationName>\n") else "",
    if (nzchar(xml_escape(person$position)))     paste0("\t\t\t<positionName>", xml_escape(person$position), "</positionName>\n") else "",
    "\t\t\t<address>\n",
    if (nzchar(xml_escape(person$delivery_point))) paste0("\t\t\t\t<deliveryPoint>", xml_escape(person$delivery_point), "</deliveryPoint>\n") else "",
    if (nzchar(xml_escape(person$city)))           paste0("\t\t\t\t<city>", xml_escape(person$city), "</city>\n") else "",
    if (nzchar(xml_escape(person$admin_area)))     paste0("\t\t\t\t<administrativeArea>", xml_escape(person$admin_area), "</administrativeArea>\n") else "",
    if (nzchar(xml_escape(person$country)))        paste0("\t\t\t\t<country>", xml_escape(person$country), "</country>\n") else "",
    "\t\t\t</address>\n",
    if (nzchar(xml_escape(person$email))) paste0("\t\t\t<electronicMailAddress>", xml_escape(person$email), "</electronicMailAddress>\n") else "",
    if (!is.null(role) && nzchar(role))   paste0("\t\t\t<role>", xml_escape(role), "</role>\n") else "",
    "\t\t</", tag, ">\n"
  )
}

random_uuid <- function() {
  hex <- function(n) paste(sample(c(0:9, letters[1:6]), n, replace = TRUE), collapse = "")
  paste(hex(8), hex(4), hex(4), hex(4), hex(12), sep = "-")
}

#' Build a GBIF/OBIS-profile eml.xml document describing a dataset.
#'
#' @param package_id A UUID for this metadata package (auto-generated if NULL)
#' @param title Dataset title
#' @param creator,metadata_provider,contact Person lists with elements:
#'   given_name, sur_name, organization, position, email, delivery_point,
#'   city, admin_area, country
#' @param associated_party Optional person list (as above) plus `role`, or NULL
#' @param pub_date Publication date (Date or "YYYY-MM-DD" string)
#' @param abstract_paragraphs Character vector - one <para> per element
#' @param keywords Character vector
#' @param license_url,license_title Intellectual rights license URL + display title
#' @param distribution_url Optional informational URL for the dataset
#' @param method_steps Character vector - one <methodStep><description> per element
#' @param study_extent_description,sampling_description Free text
#' @param project_id,project_title,project_abstract,funding,
#'   study_area_description,design_description Free text project fields
#'   (project block omitted entirely if project_id is NULL/empty)
#' @return A single character string: the complete eml.xml document
build_eml_xml <- function(package_id = NULL,
                           title,
                           creator,
                           metadata_provider,
                           contact,
                           associated_party = NULL,
                           pub_date = Sys.Date(),
                           abstract_paragraphs,
                           keywords = character(),
                           license_url = "https://creativecommons.org/licenses/by/4.0/legalcode",
                           license_title = license_url,
                           distribution_url = NULL,
                           method_steps = character(),
                           study_extent_description = "",
                           sampling_description = "",
                           project_id = NULL,
                           project_title = NULL,
                           project_abstract = NULL,
                           funding = NULL,
                           study_area_description = NULL,
                           design_description = NULL) {

  if (is.null(package_id) || !nzchar(package_id)) package_id <- random_uuid()

  abstract_paragraphs <- abstract_paragraphs[nzchar(abstract_paragraphs)]
  abstract_xml <- paste(
    vapply(abstract_paragraphs, function(p) paste0("\t\t\t<para>", xml_escape(p), "</para>"), character(1)),
    collapse = "\n"
  )

  keywords <- keywords[nzchar(keywords)]
  keywords_xml <- if (length(keywords) > 0) {
    paste0(
      "\t\t<keywordSet>\n",
      paste(vapply(keywords, function(k) paste0("\t\t\t<keyword>", xml_escape(k), "</keyword>"), character(1)), collapse = "\n"), "\n",
      "\t\t\t<keywordThesaurus>N/A</keywordThesaurus>\n",
      "\t\t</keywordSet>\n"
    )
  } else ""

  method_steps <- method_steps[nzchar(method_steps)]
  methods_xml <- paste(vapply(method_steps, function(s) {
    paste0(
      "\t\t<methodStep>\n\t\t\t<description>\n\t\t\t\t<para>", xml_escape(s), "</para>\n\t\t\t</description>\n\t\t</methodStep>\n"
    )
  }, character(1)), collapse = "")

  associated_party_xml <- if (!is.null(associated_party)) {
    person_xml("associatedParty", associated_party, role = if (!is.null(associated_party$role) && nzchar(associated_party$role)) associated_party$role else "PUBLISHER")
  } else ""

  distribution_xml <- if (!is.null(distribution_url) && nzchar(distribution_url)) {
    paste0(
      "\t<distribution scope=\"document\">\n\t\t<online>\n\t\t\t<url function=\"information\">", xml_escape(distribution_url), "</url>\n\t\t</online>\n\t</distribution>\n"
    )
  } else ""

  project_xml <- if (!is.null(project_id) && nzchar(project_id)) {
    paste0(
      "\t<project id=\"", xml_escape(project_id), "\">\n",
      "\t\t<title>", xml_escape(project_title), "</title>\n",
      "\t\t<abstract>\n\t\t\t<para>", xml_escape(project_abstract), "</para>\n\t\t</abstract>\n",
      if (!is.null(funding) && nzchar(funding)) paste0("\t\t<funding>\n\t\t\t<para>", xml_escape(funding), "</para>\n\t\t</funding>\n") else "",
      if (!is.null(study_area_description) && nzchar(study_area_description)) paste0(
        "\t\t<studyAreaDescription>\n\t\t\t<descriptor name=\"generic\" citableClassificationSystem=\"false\">\n\t\t\t\t<descriptorValue>",
        xml_escape(study_area_description), "</descriptorValue>\n\t\t\t</descriptor>\n\t\t</studyAreaDescription>\n"
      ) else "",
      if (!is.null(design_description) && nzchar(design_description)) paste0(
        "\t\t<designDescription>\n\t\t\t<description>\n\t\t\t\t<para>", xml_escape(design_description), "</para>\n\t\t\t</description>\n\t\t</designDescription>\n"
      ) else "",
      "\t</project>\n"
    )
  } else ""

  xml <- paste0(
    '<?xml version="1.0" encoding="UTF-8"?>\n',
    '<eml:eml xmlns:eml="https://eml.ecoinformatics.org/eml-2.2.0"\n',
    '         xmlns:dc="http://purl.org/dc/terms/"\n',
    '         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"\n',
    '         xsi:schemaLocation="https://eml.ecoinformatics.org/eml-2.2.0 https://rs.gbif.org/schema/eml-gbif-profile/1.3/eml.xsd"\n',
    '         packageId="', xml_escape(package_id), '" system="http://gbif.org" scope="system"\n',
    '         xml:lang="eng">\n',
    '\t<dataset>\n',
    '\t\t<title>', xml_escape(title), '</title>\n',
    person_xml("creator", creator),
    person_xml("metadataProvider", metadata_provider),
    associated_party_xml,
    '\t\t<pubDate>\n\t\t  ', format(as.Date(pub_date), "%Y-%m-%d"), '\n\t\t  </pubDate>\n',
    '\t\t<language>ENGLISH</language>\n',
    '\t\t<abstract>\n', abstract_xml, '\n\t\t</abstract>\n',
    keywords_xml,
    '\t\t<intellectualRights>\n\t\t\t<para>This work is licensed under a\n',
    '                    <ulink url="', xml_escape(license_url), '">\n',
    '\t\t<citetitle>', xml_escape(license_title), '</citetitle>\n\t</ulink>.\n',
    '                </para>\n\t</intellectualRights>\n',
    distribution_xml,
    '\t<maintenance>\n\t\t<description>\n\t\t\t<para></para>\n\t\t</description>\n',
    '\t\t<maintenanceUpdateFrequency>unknown</maintenanceUpdateFrequency>\n\t</maintenance>\n',
    person_xml("contact", contact),
    '\t<methods>\n', methods_xml,
    '\t\t<sampling>\n\t\t\t<studyExtent>\n\t\t\t\t<description>\n\t\t\t\t\t<para>', xml_escape(study_extent_description), '</para>\n',
    '\t\t\t\t</description>\n\t\t\t</studyExtent>\n',
    '\t\t\t<samplingDescription>\n\t\t\t\t<para>', xml_escape(sampling_description), '</para>\n\t\t\t</samplingDescription>\n',
    '\t\t</sampling>\n\t</methods>\n',
    project_xml,
    '\t</dataset>\n',
    '<additionalMetadata>\n\t<metadata>\n\t\t<gbif>\n\t\t\t<dateStamp>', format(Sys.time(), "%Y-%m-%dT%H:%M:%OS3", tz = "UTC"), 'Z</dateStamp>\n',
    '\t\t</gbif>\n\t</metadata>\n</additionalMetadata>\n</eml:eml>\n'
  )

  # Fail loudly on a structural mistake here, rather than shipping
  # broken XML in the archive.
  xml2::read_xml(xml)

  xml
}
