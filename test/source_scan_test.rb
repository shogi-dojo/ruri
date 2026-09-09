# frozen_string_literal: true

require_relative "test_helper"

class SourceScanTest < Minitest::Test
  # The function sees the raw characters between the quotes.

  def test_detects_unescaped_interpolation
    assert Ruri::SourceScan.interpolated?('a#{1+1}b')
  end

  def test_detects_leading_interpolation
    assert Ruri::SourceScan.interpolated?('#{x}')
  end

  def test_escaped_interpolation_is_not_interpolation
    refute Ruri::SourceScan.interpolated?('a\#{b}')
  end

  def test_escaped_backslash_then_interpolation_is_interpolation
    assert Ruri::SourceScan.interpolated?('a\\\\#{b}')
  end

  def test_plain_text_is_not_interpolation
    refute Ruri::SourceScan.interpolated?('plain')
    refute Ruri::SourceScan.interpolated?('# hash')
    refute Ruri::SourceScan.interpolated?('')
  end
end
