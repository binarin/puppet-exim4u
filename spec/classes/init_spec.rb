require 'spec_helper'
describe 'exim4u' do

  context 'with defaults for all parameters' do
    it { should contain_class('exim4u') }
  end
end
