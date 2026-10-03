module StatementExtraction
  class Extractor
    attr_reader :statement_import

    def initialize(statement_import)
      @statement_import = statement_import
    end

    def extract(progress_callback: nil)
      result = if statement_import.csv_uploaded?
        CsvExtractor.new(
          raw_csv: statement_import.account_statement.original_file.download,
          filename: statement_import.original_filename
        ).extract
      elsif statement_import.pdf_uploaded?
        PdfExtractor.new(statement_import).extract(progress_callback: progress_callback)
      else
        raise ArgumentError, "No statement file uploaded"
      end

      ProfileMatcher.new(family: statement_import.family, result: result, accounts: statement_import.authorized_accounts).call
    end
  end
end
