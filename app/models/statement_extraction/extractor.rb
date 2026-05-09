module StatementExtraction
  class Extractor
    attr_reader :statement_import

    def initialize(statement_import)
      @statement_import = statement_import
    end

    def extract
      result = if statement_import.csv_uploaded?
        CsvExtractor.new(
          raw_csv: statement_import.raw_file_str,
          filename: statement_import.original_filename
        ).extract
      elsif statement_import.pdf_uploaded?
        PdfExtractor.new(statement_import).extract
      else
        raise ArgumentError, "No statement file uploaded"
      end

      ProfileMatcher.new(family: statement_import.family, result: result).call
    end
  end
end
